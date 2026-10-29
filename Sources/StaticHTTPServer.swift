import Foundation
import Network

/// Bundled web assets, loaded once at startup so no request touches the disk.
///
/// A file of the same name in `~/Library/Application Support/remoteMac/web/`
/// wins over the bundled copy, so the UI can be iterated without rebuilding.
/// Only names already in the fixed table below are ever looked up, so this is
/// not a path-traversal vector.
enum AssetCache {
    struct Item { let file: String; let data: Data; let mime: String }

    /// Every file the server will ever serve, with its content type. Routes are
    /// resolved against this fixed table, so a request can never name a file
    /// that isn't listed here — which is what makes path traversal a non-issue.
    private static let mimes: [String: String] = [
        "index.html":          "text/html; charset=utf-8",
        "app.js":              "application/javascript; charset=utf-8",
        "logic.js":            "application/javascript; charset=utf-8",
        "deck.js":             "application/javascript; charset=utf-8",
        "style.css":           "text/css; charset=utf-8",
        "manifest.webmanifest": "application/manifest+json",
        "icon-180.png":        "image/png",
        "icon-192.png":        "image/png",
        "icon-512.png":        "image/png",
    ]

    private static let routes: [String: String] = [
        "/":                                "index.html",
        "/index.html":                      "index.html",
        "/app.js":                          "app.js",
        "/logic.js":                        "logic.js",
        "/deck.js":                         "deck.js",
        "/style.css":                       "style.css",
        "/manifest.webmanifest":            "manifest.webmanifest",
        "/favicon.ico":                     "icon-192.png",
        "/icon-180.png":                    "icon-180.png",
        "/icon-192.png":                    "icon-192.png",
        "/icon-512.png":                    "icon-512.png",
        "/apple-touch-icon.png":            "icon-180.png",
    ]

    /// Live-edit directory, checked per request. See the type comment.
    static let overrideDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("remoteMac/web", isDirectory: true)

    /// Source directory used when there is no app bundle to read from — set by
    /// the test suite, and useful when running the helper straight from a build
    /// directory. Never consulted for anything outside `mimes`.
    private static let sourceDir: URL? = {
        guard let path = ProcessInfo.processInfo.environment["REMOTEMAC_WEB_DIR"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    /// Read once at startup so no request touches the disk, except for the
    /// override directory which is checked per request by design.
    private static let preloaded: [String: Data] = {
        var out: [String: Data] = [:]
        for file in mimes.keys {
            if let directory = sourceDir,
               let data = try? Data(contentsOf: directory.appendingPathComponent(file)) {
                out[file] = data
                continue
            }
            guard let dot = file.lastIndex(of: ".") else { continue }
            let stem = String(file[..<dot])
            let ext = String(file[file.index(after: dot)...])
            if let url = Bundle.main.url(forResource: stem, withExtension: ext),
               let data = try? Data(contentsOf: url) {
                out[file] = data
            }
        }
        return out
    }()

    static func item(for path: String) -> Item? {
        guard let file = routes[path], let mime = mimes[file] else { return nil }
        if let data = try? Data(contentsOf: overrideDir.appendingPathComponent(file)) {
            return Item(file: file, data: data, mime: mime)
        }
        guard let data = preloaded[file] else { return nil }
        return Item(file: file, data: data, mime: mime)
    }
}

/// The HTTP statuses this server returns. An enum rather than inline strings so
/// a typo cannot ship as a malformed status line.
enum Status {
    case ok, badRequest, unauthorized, forbidden, notFound, methodNotAllowed
    case misdirected, bodyTooLarge, headersTooLarge, tooManyRequests, serverError

    var line: String {
        switch self {
        case .ok:               return "200 OK"
        case .badRequest:       return "400 Bad Request"
        case .unauthorized:     return "401 Unauthorized"
        case .forbidden:        return "403 Forbidden"
        case .notFound:         return "404 Not Found"
        case .methodNotAllowed: return "405 Method Not Allowed"
        case .misdirected:      return "421 Misdirected Request"
        case .bodyTooLarge:     return "413 Payload Too Large"
        case .headersTooLarge:  return "431 Request Header Fields Too Large"
        case .tooManyRequests:  return "429 Too Many Requests"
        case .serverError:      return "500 Internal Server Error"
        }
    }
}

enum ContentType {
    static let text = "text/plain; charset=utf-8"
    static let json = "application/json"
}

/// Serves the phone's web app and the one pairing endpoint, and nothing else.
///
/// Deliberately *not* a general HTTP server: GET and POST only, a fixed route
/// table, no keep-alive, no pipelining, hard caps on header and body size, and a
/// short idle timeout. The static assets are unauthenticated on purpose — the page
/// contains no secrets, and gating it would require an ambient credential (a
/// cookie), which is precisely the thing that makes cross-site WebSocket
/// hijacking possible. Authentication lives on the control socket instead.
final class StaticHTTPServer {
    private let port: UInt16
    /// Published to the client via /config.json. The page must not hardcode this:
    /// duplicating the port in both the server and the client means they can
    /// drift, and the only symptom is a page that never connects.
    private let controlPort: UInt16
    private let sessions: SessionStore
    /// nil serves plaintext. The integration suite drives these listeners over
    /// hand-rolled POSIX sockets, so it keeps using that path.
    private let tls: NWProtocolTLS.Options?
    private let queue = DispatchQueue(label: "com.remotemac.http")
    private var listener: NWListener?
    /// Sessions must be retained: an NWConnection callback chain does not keep
    /// its handler object alive, so a Session only held by a local would be
    /// deallocated before it could answer.
    private var inFlight: [ObjectIdentifier: Session] = [:]

    private static let maxHeaderBytes = 8 * 1024
    private static let maxBodyBytes = 4 * 1024
    private static let maxConcurrent = 16
    private static let idleTimeout: TimeInterval = 10

    /// Host values accepted. Recomputed on each start so a DHCP change is picked up.
    private var acceptableHosts: Set<String> = []
    private var acceptableOrigins: Set<String> = []

    var onPairSuccess: (() -> Void)?

    /// Whether the helper currently holds Accessibility. Published to the client
    /// so the phone can say "the Mac hasn't granted permission" instead of
    /// appearing to work while every event is silently dropped.
    var accessibilityGranted: () -> Bool = { false }

    var isSecure: Bool { tls != nil }

    init(port: UInt16, controlPort: UInt16, sessions: SessionStore,
         tls: NWProtocolTLS.Options? = nil) {
        self.port = port
        self.controlPort = controlPort
        self.sessions = sessions
        self.tls = tls
    }

    func start() throws {
        acceptableHosts = NetworkInfo.acceptableHosts(httpPort: port)
        acceptableOrigins = NetworkInfo.acceptableOrigins(httpPort: port, secure: isSecure)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.allowLocalEndpointReuse = true

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
    }

    /// Re-read the local addresses, e.g. after joining a different network.
    func refreshAcceptedNames() {
        queue.async { [weak self] in
            guard let self else { return }
            self.acceptableHosts = NetworkInfo.acceptableHosts(httpPort: self.port)
            self.acceptableOrigins = NetworkInfo.acceptableOrigins(httpPort: self.port,
                                                                   secure: self.isSecure)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard inFlight.count < StaticHTTPServer.maxConcurrent else {
            connection.cancel()
            return
        }
        let session = Session(connection: connection, server: self)
        inFlight[ObjectIdentifier(session)] = session
        session.start()
    }

    fileprivate func sessionFinished(_ session: Session) {
        queue.async { [weak self] in
            self?.inFlight[ObjectIdentifier(session)] = nil
        }
    }

    // MARK: - One request/response exchange

    fileprivate final class Session {
        private let connection: NWConnection
        private weak var server: StaticHTTPServer?
        private var buffer = Data()
        private var finished = false
        private var timeout: DispatchWorkItem?

        init(connection: NWConnection, server: StaticHTTPServer) {
            self.connection = connection
            self.server = server
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.finish() }
                if case .cancelled = state { self?.finish() }
            }
            let work = DispatchWorkItem { [weak self] in self?.finish() }
            timeout = work
            DispatchQueue.global().asyncAfter(deadline: .now() + StaticHTTPServer.idleTimeout, execute: work)
            connection.start(queue: .global(qos: .userInitiated))
            read()
        }

        private func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self, !self.finished else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    // Refuse to accumulate unbounded request data.
                    if self.buffer.count > StaticHTTPServer.maxHeaderBytes + StaticHTTPServer.maxBodyBytes {
                        self.respond(status: .headersTooLarge, body: "request too large")
                        return
                    }
                    if self.tryHandle() { return }
                }
                if isComplete || error != nil { self.finish(); return }
                self.read()
            }
        }

        /// Returns true once a complete request has been handled.
        private func tryHandle() -> Bool {
            guard let headerEnd = Session.findHeaderEnd(buffer) else { return false }
            guard headerEnd <= StaticHTTPServer.maxHeaderBytes else {
                respond(status: .headersTooLarge, body: "headers too large")
                return true
            }
            guard let head = String(data: buffer.prefix(headerEnd), encoding: .utf8) else {
                respond(status: .badRequest, body: "bad encoding")
                return true
            }

            var lines = head.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                respond(status: .badRequest, body: "no request line")
                return true
            }
            lines.removeFirst()

            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else {
                respond(status: .badRequest, body: "bad request line")
                return true
            }
            let method = String(parts[0]).uppercased()
            let target = String(parts[1])

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            // --- Host validation: the DNS-rebinding gate. ---
            let host = (headers["host"] ?? "").lowercased()
            guard server?.acceptableHosts.contains(host) == true else {
                respond(status: .misdirected, body: "unrecognised Host header")
                return true
            }

            let path = target.split(separator: "?").first.map(String.init) ?? target

            switch (method, path) {
            case ("GET", "/config.json"):
                respond(status: .ok,
                        body: Reply.config(controlPort: server?.controlPort ?? 0,
                                           accessibility: server?.accessibilityGranted() ?? false),
                        contentType: ContentType.json)
            case ("GET", _):
                serveAsset(path)
            case ("POST", "/pair"):
                let bodyStart = headerEnd + 4
                let declared = Int(headers["content-length"] ?? "") ?? 0
                guard declared <= StaticHTTPServer.maxBodyBytes else {
                    respond(status: .bodyTooLarge, body: "body too large")
                    return true
                }
                guard buffer.count >= bodyStart + declared else { return false }   // wait for the body
                let body = buffer.subdata(in: bodyStart ..< (bodyStart + declared))
                handlePair(body: body, origin: headers["origin"])
            default:
                respond(status: .methodNotAllowed, body: "method not allowed")
            }
            return true
        }

        private func serveAsset(_ path: String) {
            guard let item = AssetCache.item(for: path) else {
                respond(status: .notFound, body: "not found")
                return
            }
            send(Session.response(status: .ok, contentType: item.mime, body: item.data))
        }

        /// `POST /pair` with `pin=NNNNNN`, answering JSON.
        ///
        /// Origin is validated here too. A cross-origin page can still issue the
        /// POST (it is a CORS-simple request) and cannot read the reply, but
        /// rejecting it outright means a hostile page cannot even blind-brute the
        /// PIN — on top of the server-side rate limit.
        private func handlePair(body: Data, origin: String?) {
            if let origin, server?.acceptableOrigins.contains(origin.lowercased()) != true {
                respond(status: .forbidden, body: Reply.pairingError("bad_origin"), contentType: ContentType.json)
                return
            }

            guard let text = String(data: body, encoding: .utf8) else {
                respond(status: .badRequest, body: Reply.pairingError("bad_body"), contentType: ContentType.json)
                return
            }
            var pin: String?
            for field in text.split(separator: "&") {
                let kv = field.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "pin" {
                    pin = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }

            guard let sessions = server?.sessions else {
                respond(status: .serverError, body: Reply.pairingError("no_store"), contentType: ContentType.json)
                return
            }

            switch sessions.pair(pin: pin ?? "", label: "phone") {
            case .success(let token):
                server?.onPairSuccess?()
                respond(status: .ok, body: Reply.pairingToken(token), contentType: ContentType.json)
            case .wrongPIN:
                respond(status: .unauthorized, body: Reply.pairingError("wrong_pin"), contentType: ContentType.json)
            case .throttled(let retryAfter):
                respond(status: .tooManyRequests,
                        body: Reply.pairingThrottled(retryAfter: Int(retryAfter.rounded(.up))),
                        contentType: ContentType.json)
            }
        }

        private func respond(status: Status, body: String, contentType: String = ContentType.text) {
            send(Session.response(status: status, contentType: contentType, body: Data(body.utf8)))
        }

        /// The only place that writes a response head, so every reply carries
        /// the same hardening headers — including the 404s and 400s, which are
        /// the ones easy to forget when each call site builds its own.
        private static func response(status: Status, contentType: String, body: Data) -> Data {
            let headers = [
                "HTTP/1.1 \(status.line)",
                "Content-Type: \(contentType)",
                "Content-Length: \(body.count)",
                "Cache-Control: no-store",
                // The page embeds no remote content and is never meant to be framed.
                "X-Content-Type-Options: nosniff",
                "X-Frame-Options: DENY",
                "Referrer-Policy: no-referrer",
                "Connection: close",
            ]
            var response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            response.append(body)
            return response
        }

        private func send(_ data: Data) {
            guard !finished else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.finish()
            })
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            connection.cancel()
            server?.sessionFinished(self)
        }

        private static func findHeaderEnd(_ data: Data) -> Int? {
            let needle = Data("\r\n\r\n".utf8)
            return data.range(of: needle)?.lowerBound
        }
    }
}
