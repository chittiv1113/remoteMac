import ApplicationServices
import Foundation

/// Notices when a text field gains or loses focus on the Mac.
///
/// The phone uses this to bring up its keyboard view as soon as you click into
/// something you can type in, instead of making you switch views by hand.
///
/// **It reads the focused element's *role* and nothing else.** Never its value,
/// never its title, never the surrounding text. Reading the contents of a
/// focused field is what separates this from a keylogger, so the only fact that
/// leaves this file is a boolean: "something typable has focus". See
/// SECURITY.md.
///
/// Polling rather than an AXObserver: observers must be attached per
/// application and re-attached on every app switch, which is a lot of moving
/// parts for a question we can answer cheaply. One system-wide query at 2.5 Hz
/// is a negligible amount of IPC, and it cannot get out of sync.
final class FocusWatcher {
    /// Roles that accept typed text.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    /// Subroles worth treating as text even when the role is generic. Secure
    /// fields are included deliberately: you still want the keyboard when
    /// typing a password, and only the boolean is reported either way.
    private static let textSubroles: Set<String> = [
        "AXSearchField",
        "AXSecureTextField",
    ]

    private let queue = DispatchQueue(label: "com.remotemac.focus", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastKnown: Bool?

    /// Fires only when the answer changes, so the client is not woken 2.5 times
    /// a second to be told the same thing.
    var onChange: ((Bool) -> Void)?

    private let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // An unresponsive application must not stall the poll.
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 0.4, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastKnown = nil
    }

    /// Forget the cached answer so the next poll reports afresh — used when a
    /// controller connects, so it learns the current state immediately.
    func resendOnNextPoll() {
        queue.async { [weak self] in self?.lastKnown = nil }
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let isText = focusedElementAcceptsText()
        guard isText != lastKnown else { return }
        lastKnown = isText
        let value = isText
        DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
    }

    private func focusedElementAcceptsText() -> Bool {
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let raw = focused else { return false }

        // CFTypeRef is only an AXUIElement when the attribute actually resolved.
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let element = raw as! AXUIElement

        if let role = string(of: element, kAXRoleAttribute as CFString),
           FocusWatcher.textRoles.contains(role) {
            return true
        }
        if let subrole = string(of: element, kAXSubroleAttribute as CFString),
           FocusWatcher.textSubroles.contains(subrole) {
            return true
        }
        return false
    }

    private func string(of element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }
}
