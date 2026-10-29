import Foundation
import Network

/// The authenticated control channel.
///
/// Framing, masking, fragmentation, the close handshake, ping/pong and the
/// message size cap are all Apple's `NWProtocolWebSocket`. That is a deliberate
/// choice rather than a convenience: frame parsing is the part of this server
/// that reads attacker-controlled bytes before any check has run, so it is the
/// last place to hand-roll anything.
///
/// Three gates, in order:
///   1. `Origin` must exactly match the page's origin — checked during the
///      handshake, before a connection object exists.
///   2. The first message must be a valid `auth` frame carrying a paired token.
///      The token is explicit, never a cookie, so no browser auto-attaches it
///      and cross-site hijacking is impossible by construction rather than by
///      policy.
///   3. Only one authenticated controller may send input at a time.
final class ControlSocket {
    private let port: UInt16
    private let httpPort: UInt16
    private let sessions: SessionStore
    /// nil serves plaintext; see the note in StaticHTTPServer.
    private let tls: NWProtocolTLS.Options?
    private let queue = DispatchQueue(label: "com.remotemac.control")
    private var listener: NWListener?

    private var controllers: [ObjectIdentifier: Controller] = [:]
    private var leaseHolder: ObjectIdentifier?

    private static let maxConnections = 8
    private static let authTimeout: TimeInterval = 10

    /// Set false by the menu bar's Pause control; input is dropped while paused.
    private(set) var isPaused = false

    var onCommand: ((Command, Controller) -> Void)?
    var onControllerChange: ((Int) -> Void)?

    init(port: UInt16, httpPort: UInt16, sessions: SessionStore,
         tls: NWProtocolTLS.Options? = nil) {
        self.port = port
        self.httpPort = httpPort
        self.sessions = sessions
        self.tls = tls
    }

    func start() throws {
        // The page is served over the same scheme, so a legitimate upgrade
        // carries an https Origin once TLS is on.
        let acceptable = NetworkInfo.acceptableOrigins(httpPort: httpPort, secure: tls != nil)

        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Limits.maxMessageBytes
        // Gate 1. Runs during the handshake; a reject never becomes a connection.
        ws.setClientRequestHandler(queue) { (_: [String], headers: [(name: String, value: String)]) in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value.lowercased()
            guard let origin, acceptable.contains(origin) else {
                NSLog("[ControlSocket] rejected handshake, origin=%@", origin ?? "<none>")
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true          // small pointer frames must not wait on Nagle
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let params = NWParameters(tls: tls, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .responsiveData
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        disconnectAll()
    }

    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isPaused = paused
            if paused {
                EventInjector.releaseAll()
                for c in self.controllers.values { c.send(json: Reply.paused) }
            } else {
                for c in self.controllers.values { c.send(json: Reply.resumed) }
            }
        }
    }

    /// Send an unsolicited message to whoever currently holds the input lease.
    func notifyController(json: String) {
        queue.async { [weak self] in
            guard let self, let holder = self.leaseHolder,
                  let controller = self.controllers[holder],
                  controller.isAuthenticated else { return }
            controller.send(json: json)
        }
    }

    func disconnectAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for c in self.controllers.values { c.close() }
            self.controllers.removeAll()
            self.leaseHolder = nil
            EventInjector.releaseAll()
            self.notifyCount()
        }
    }

    private func notifyCount() {
        let n = controllers.values.filter(\.isAuthenticated).count
        DispatchQueue.main.async { [weak self] in self?.onControllerChange?(n) }
    }

    private func accept(_ connection: NWConnection) {
        guard controllers.count < ControlSocket.maxConnections else {
            connection.cancel()
            return
        }
        let controller = Controller(connection: connection, socket: self, sessions: sessions)
        controllers[ObjectIdentifier(controller)] = controller
        controller.start()
    }

    // MARK: - Lease

    /// Gate 3. First authenticated controller wins; later ones are told it's busy.
    fileprivate func claimLease(_ controller: Controller) -> Bool {
        let key = ObjectIdentifier(controller)
        if let holder = leaseHolder, holder != key, controllers[holder] != nil {
            return false
        }
        leaseHolder = key
        return true
    }

    fileprivate func releaseLease(_ controller: Controller) {
        let key = ObjectIdentifier(controller)
        if leaseHolder == key { leaseHolder = nil }
    }

    fileprivate func holdsLease(_ controller: Controller) -> Bool {
        leaseHolder == ObjectIdentifier(controller)
    }

    fileprivate func remove(_ controller: Controller) {
        let key = ObjectIdentifier(controller)
        controllers[key] = nil
        if leaseHolder == key {
            leaseHolder = nil
            // Whoever had the lease may have been mid-drag.
            EventInjector.releaseAll()
        }
        notifyCount()
    }

    fileprivate func dispatch(_ command: Command, from controller: Controller) {
        guard !isPaused else { return }
        onCommand?(command, controller)
    }

    fileprivate var controlQueue: DispatchQueue { queue }

    // MARK: - One connected client

    final class Controller {
        private let connection: NWConnection
        private weak var socket: ControlSocket?
        private let sessions: SessionStore
        private var limiter = RateLimiter()
        private var authTimer: DispatchWorkItem?
        private var closed = false

        private(set) var isAuthenticated = false

        private struct AuthFrame: Decodable { let v: Int?; let t: String; let token: String? }

        init(connection: NWConnection, socket: ControlSocket, sessions: SessionStore) {
            self.connection = connection
            self.socket = socket
            self.sessions = sessions
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.teardown()
                case .ready: self?.send(json: Reply.authRequired)
                default: break
                }
            }
            // Gate 2 has a deadline: an unauthenticated socket is not left open.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isAuthenticated else { return }
                self.send(json: Reply.authTimeout)
                self.close()
            }
            authTimer = work
            socket?.controlQueue.asyncAfter(deadline: .now() + ControlSocket.authTimeout, execute: work)

            connection.start(queue: socket?.controlQueue ?? .global())
            receive()
        }

        private func receive() {
            connection.receiveMessage { [weak self] data, context, _, error in
                guard let self, !self.closed else { return }

                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                    self.close()
                    return
                }
                if let error {
                    NSLog("[ControlSocket] receive error: %@", error.localizedDescription)
                    self.close()
                    return
                }
                if let data, !data.isEmpty { self.handle(data) }
                if !self.closed { self.receive() }
            }
        }

        private func handle(_ data: Data) {
            guard limiter.allow() else {
                send(json: Reply.error("rate_limited"))
                return
            }

            if !isAuthenticated {
                authenticate(data)
                return
            }

            do {
                let command = try Command.decode(data)
                guard socket?.holdsLease(self) == true else {
                    send(json: Reply.busy)
                    return
                }
                socket?.dispatch(command, from: self)
            } catch let error as ValidationError {
                // A protocol-shape description, never message content.
                send(json: Reply.error(error.description))
            } catch {
                send(json: Reply.error("invalid"))
            }
        }

        private func authenticate(_ data: Data) {
            guard data.count <= Limits.maxCommandBytes,
                  let frame = try? JSONDecoder().decode(AuthFrame.self, from: data),
                  frame.v == Limits.protocolVersion,
                  frame.t == "auth" else {
                send(json: Reply.authFailed)
                close()
                return
            }
            guard sessions.isAuthorized(token: frame.token) else {
                send(json: Reply.authFailed)
                close()
                return
            }

            guard socket?.claimLease(self) == true else {
                send(json: Reply.busy)
                close()
                return
            }

            isAuthenticated = true
            authTimer?.cancel()
            send(json: Reply.welcome)
            socket?.notifyCount()
        }

        func send(json: String) {
            guard !closed else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
            connection.send(content: Data(json.utf8), contentContext: context,
                            isComplete: true, completion: .contentProcessed { _ in })
        }

        func close() {
            guard !closed else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = .protocolCode(.normalClosure)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            connection.send(content: nil, contentContext: context, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.teardown() })
        }

        private func teardown() {
            guard !closed else { return }
            closed = true
            authTimer?.cancel()
            connection.cancel()
            socket?.releaseLease(self)
            socket?.remove(self)
        }
    }
}
