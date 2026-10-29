import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Owns the two listeners, and the observable state the menu bar renders.
///
/// The HTTP server (`httpPort`) serves the phone's web app and the pairing
/// endpoint. The control socket (`controlPort`) carries authenticated input.
/// They are separate listeners because `NWProtocolWebSocket` cannot share one
/// with plain HTTP file serving.
///
/// That split has a security consequence worth stating out loud: the control
/// socket is intentionally a *different origin* from the page, so no browser
/// will ever auto-attach a credential to it. Authentication is an explicit
/// token in the first frame, which is what makes cross-site WebSocket
/// hijacking impossible here rather than merely unlikely.
final class Helper: ObservableObject {
    @Published var isRunning = false
    @Published var httpURL = ""
    @Published var alternateURL = ""
    @Published var activeControllers = 0
    @Published var accessibilityGranted = false
    @Published var isPaused = false

    @Published var pin = ""
    @Published var pairedDevices = 0

    /// Diagnostics only. Counts and a content-free label — never text or key codes.
    @Published var commandCount = 0
    @Published var lastCommand = "-"

    let httpPort: UInt16 = 8765
    let controlPort: UInt16 = 8766

    private let sessions = SessionStore()
    /// Loaded once. Nil means no certificate is installed, and both listeners
    /// fall back to plaintext — run scripts/make-tls-cert.sh to change that.
    private let tls = TLSIdentity.options()
    private var http: StaticHTTPServer?
    private var control: ControlSocket?
    private var refreshTimer: Timer?

    /// Tells the phone when something typable gains focus, so its keyboard view
    /// can come up by itself. Reports a boolean only — never field contents.
    private let focusWatcher = FocusWatcher()

    /// Whether this Mac's `.local` name resolves. Checked off the main thread,
    /// because a failing mDNS lookup can block.
    private var localNameResolves = false

    /// Command routing lives in `CommandRouter` so it is testable without an
    /// app or real input injection.
    private let router: CommandRouter

    init() {
        Helper.raiseFileDescriptorLimit()
        router = CommandRouter(
            deck: DeckStore.load() ?? .empty,
            effects: CommandRouter.Effects(
                inject: { EventInjector.perform($0) },
                openURL: { EventInjector.open(url: $0) },
                openApplication: { EventInjector.openApplication(at: $0) },
                allowedAppPaths: { AppList.allowedPaths() },
                appListJSON: { AppList.json() }
            )
        )

        pin = sessions.pin
        pairedDevices = sessions.pairedDeviceCount

        EventInjector.startWatchingDisplays()
        AppList.warmUp()
        focusWatcher.start()

        start()
        refreshAccessibility()

        // Ask macOS for Accessibility on launch if we don't have it. This is the
        // normal route: the system dialog registers the app under its current
        // code identity, which is more reliable than asking a person to locate
        // the bundle by hand — and a stale entry from a previous identity
        // otherwise looks switched-on while granting nothing.
        if !accessibilityGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.promptAccessibility()
            }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshAccessibility()
            self?.http?.refreshAcceptedNames()
            self?.refreshLocalName()
        }
    }

    // MARK: - Lifecycle

    /// Whether traffic is encrypted. Drives the scheme shown in the menu bar,
    /// the Origin the control socket accepts, and whether the phone can reach
    /// its microphone at all.
    var isSecure: Bool { tls != nil }

    func start() {
        let http = StaticHTTPServer(port: httpPort, controlPort: controlPort,
                                    sessions: sessions, tls: tls)
        http.accessibilityGranted = { AXIsProcessTrusted() }
        http.onPairSuccess = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.pairedDevices = self.sessions.pairedDeviceCount }
        }

        let control = ControlSocket(port: controlPort, httpPort: httpPort,
                                    sessions: sessions, tls: tls)
        control.onCommand = { [weak self] command, controller in
            self?.router.handle(command) { controller.send(json: $0) }
        }
        router.onActivity = { [weak self] label in
            DispatchQueue.main.async {
                self?.commandCount += 1
                self?.lastCommand = label
            }
        }
        control.onControllerChange = { [weak self] count in
            self?.activeControllers = count
            // A newly connected phone should learn the current state at once
            // rather than waiting for the next change.
            if count > 0 { self?.focusWatcher.resendOnNextPoll() }
        }
        focusWatcher.onChange = { [weak self] isText in
            self?.control?.notifyController(json: Reply.focus(text: isText))
        }

        do {
            try http.start()
            try control.start()
            self.http = http
            self.control = control
            isRunning = true
            refreshLocalName()
        } catch {
            isRunning = false
            NSLog("[Helper] could not start listeners (ports %u/%u may be in use): %@",
                  UInt32(httpPort), UInt32(controlPort), error.localizedDescription)
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        focusWatcher.stop()
        control?.stop()
        http?.stop()
        control = nil
        http = nil
        isRunning = false
    }

    /// A phone can hold many sockets open while reconnecting on a flaky link,
    /// and the default soft limit is low enough to matter.
    private static func raiseFileDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target: rlim_t = 4096
        guard limit.rlim_cur < target else { return }
        limit.rlim_cur = min(target, limit.rlim_max)
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }

    // MARK: - Menu bar actions

    func setPaused(_ paused: Bool) {
        isPaused = paused
        control?.setPaused(paused)
    }

    func regeneratePIN() {
        sessions.regeneratePIN()
        pin = sessions.pin
    }

    /// Forget every paired device and drop live connections. A phone must pair
    /// again with a fresh PIN.
    func revokeAllDevices() {
        sessions.revokeAll()
        pairedDevices = 0
        control?.disconnectAll()
    }

    func disconnectControllers() {
        control?.disconnectAll()
    }

    // MARK: - Status

    /// Decide which address to show.
    ///
    /// The `.local` name is preferred because it survives DHCP changes, but only
    /// if it actually resolves — on a network that blocks mDNS it is a dead URL,
    /// and the IP is the one that works. Whichever is not chosen is offered as
    /// the alternate, so there is always a second thing to try.
    private func updateURL() {
        let ip = NetworkInfo.primaryIPv4()
        let localName = NetworkInfo.localHostName()

        let primary: String
        if localNameResolves, let localName {
            primary = url(for: localName)
        } else if let ip {
            primary = url(for: ip)
        } else {
            primary = url(for: "localhost")
        }
        if primary != httpURL { httpURL = primary }

        let alternate: String
        if localNameResolves, let ip {
            alternate = url(for: ip)
        } else if let localName {
            alternate = url(for: localName)
        } else {
            alternate = ""
        }
        if alternate != alternateURL { alternateURL = alternate }
    }

    private func url(for host: String) -> String {
        "\(isSecure ? "https" : "http")://\(host):\(httpPort)"
    }

    /// Re-check mDNS resolvability, then refresh the displayed address.
    private func refreshLocalName() {
        let name = NetworkInfo.localHostName()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolves = name.map { NetworkInfo.resolves($0) } ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.localNameResolves = resolves
                self.updateURL()
            }
        }
    }

    func refreshAccessibility() {
        let granted = AXIsProcessTrusted()
        if granted != accessibilityGranted { accessibilityGranted = granted }
    }

    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        let settings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: settings) else { return }
        NSWorkspace.shared.open(url)
    }

    func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
