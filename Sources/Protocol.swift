import CoreGraphics
import Foundation

/// Wire protocol v1, and the validation gate every inbound message passes through.
///
/// Design rule: **reject, don't clamp.** A value outside the tested range means
/// either a client bug or an attacker, and silently clamping hides both. The only
/// exception is pointer coalescing, which is a transport concern, not validation.
enum Limits {
    static let protocolVersion = 1

    /// Largest single pointer delta, in points. A real swipe produces well under
    /// this; anything larger is a bug or an attempt to fling the cursor off-screen.
    static let maxPointerDelta: Double = 200
    static let maxScrollDelta: Double = 500

    /// Per `text.insert` message, in UTF-16 units.
    static let maxTextUTF16 = 256

    /// Cap on an *input* command — everything except a deck write. A pointer
    /// packet is about 60 bytes and the largest text insert a few hundred, so
    /// nothing legitimate comes close; anything that does is a flood or a probe.
    static let maxCommandBytes = 4096

    /// Transport ceiling: the largest frame the socket will accept or send at
    /// all, also handed to `NWProtocolWebSocket.maximumMessageSize`.
    ///
    /// This is separate from `maxCommandBytes` because two messages are
    /// legitimately large, and both carry app icons as base64 PNG data URIs: a
    /// `deck.save` (bounded by `maxDeckBytes`) and the `apps` response that
    /// feeds the picker (one entry per installed application, a few hundred KB
    /// on a typical Mac). Setting one cap for both would mean either rejecting
    /// those two or letting a pointer packet be a megabyte.
    static let maxMessageBytes = 1024 * 1024

    /// Sustained command rate. Pointer moves are coalesced client-side to ~60/s,
    /// so this leaves generous headroom while bounding a flood. Note that the
    /// two large message types above are user-initiated and rare; the rate limit
    /// is what stops them being used as an amplification lever.
    static let maxCommandsPerSecond = 300

    static let maxShortcutIDLength = 64
    /// Generous because deck items embed a PNG app icon as a data URI (a few KB
    /// each), which is how the picker shows real icons.
    static let maxDeckBytes = 512 * 1024
    static let maxDeckFolders = 12
    static let maxDeckItemsPerFolder = 60
}

enum ValidationError: Error, CustomStringConvertible {
    case badJSON
    case tooLarge(Int)
    case unsupportedVersion(Int?)
    case unknownType(String)
    case missingField(String)
    case outOfRange(String, Double)
    case badEnum(String, String)
    case textTooLong(Int)
    case unknownKeyCode(Int)

    var description: String {
        switch self {
        case .badJSON:                      return "malformed JSON"
        case .tooLarge(let n):              return "message too large (\(n) bytes)"
        case .unsupportedVersion(let v):    return "unsupported protocol version \(v.map(String.init) ?? "nil")"
        case .unknownType(let t):           return "unknown command type '\(t)'"
        case .missingField(let f):          return "missing field '\(f)'"
        case .outOfRange(let f, let v):     return "field '\(f)' out of range (\(v))"
        case .badEnum(let f, let v):        return "field '\(f)' has invalid value '\(v)'"
        case .textTooLong(let n):           return "text too long (\(n) UTF-16 units)"
        case .unknownKeyCode(let c):        return "key code \(c) is not in the allowlist"
        }
    }
}

enum MouseButton: String {
    case left, right
}

enum Modifier: String, CaseIterable {
    case command, control, option, shift

    /// Virtual key code for the physical modifier key. Posting real modifier
    /// key-down/up events (rather than only setting flags) is what makes
    /// WindowServer-level hotkeys fire.
    var keyCode: CGKeyCode {
        switch self {
        case .command: return 55
        case .shift:   return 56
        case .option:  return 58
        case .control: return 59
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .shift:   return .maskShift
        case .option:  return .maskAlternate
        case .control: return .maskControl
        }
    }
}

enum SwipeDirection: String {
    case left, right, up, down
}

/// Whole-system actions, as opposed to input aimed at the focused app.
///
/// **`previousSpace` and `nextSpace` do not work on current macOS.** They
/// synthesize the documented ⌃← / ⌃→ shortcut and the event is delivered — it
/// is observable on the session event tap carrying the Control flag — but
/// WindowServer does not act on a synthesized Space switch. Measured against
/// `NSWorkspace.activeSpaceDidChangeNotification`: six combinations of event
/// source, tap location and modifier timing all leave the Space unchanged, as
/// does SkyLight's private `SLSManagedDisplaySetCurrentSpace` (which needs SIP
/// disabled to take effect).
///
/// They are kept because the protocol and the injection are correct, and the
/// restriction is the OS's rather than ours — but nothing in the UI offers
/// them, because a control that cannot work is worse than no control.
enum SystemAction: String {
    case missionControl    = "mission_control"
    case appExpose         = "app_expose"
    case previousSpace     = "previous_space"
    case nextSpace         = "next_space"
    case zoomIn            = "zoom_in"
    case zoomOut           = "zoom_out"
}

/// Allowlist of macOS virtual key codes the helper will inject.
///
/// Naming keys on the wire (`"key":"enter"`) would read better, but an allowlist
/// of codes gives the property that actually matters — no attacker-chosen
/// integer ever reaches `CGKeyCode` — and keeps one representation shared by the
/// wire format, the stored deck, and this check.
enum KeyCodes {
    /// Letters, digits, punctuation (the printable set the client's KEYMAP covers).
    static let printable: Set<Int> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,   // a s d f h g z x c v b q w e r y t
        31, 32, 34, 35, 37, 38, 40, 45, 46,                          // o u i p l j k n m
        18, 19, 20, 21, 22, 23, 25, 26, 28, 29,                      // 1-9, 0
        24, 27, 30, 33, 39, 41, 42, 43, 44, 47, 50,                  // = - ] [ ' ; \ , / . `
    ]

    /// Editing, navigation and function keys.
    static let special: Set<Int> = [
        36, 48, 49, 51, 53, 117,              // return tab space delete escape forward-delete
        115, 116, 119, 121,                   // home page-up end page-down
        123, 124, 125, 126,                   // left right down up
        122, 120, 99, 118, 96, 97, 98, 100,   // F1-F8
        101, 109, 103, 111,                   // F9-F12
    ]

    static let allowed: Set<Int> = printable.union(special)

    static func validate(_ code: Int) throws -> CGKeyCode {
        guard allowed.contains(code) else { throw ValidationError.unknownKeyCode(code) }
        return CGKeyCode(code)
    }
}

// MARK: - Commands

enum Command {
    case pointerMove(dx: Double, dy: Double)
    case pointerDown(button: MouseButton, mods: [Modifier])
    case pointerUp
    case pointerClick(button: MouseButton, count: Int, mods: [Modifier])
    case pointerScroll(dx: Double, dy: Double)
    case textInsert(String)
    case keyPress(keyCode: CGKeyCode, mods: [Modifier])
    case swipe(SwipeDirection, fingers: Int)
    case systemAction(SystemAction)
    case shortcutRun(id: String)
    case deckGet
    case deckSave(json: String)
    case appsGet
    case ping

    /// Commands safe to omit from the activity log. Logging every pointer move
    /// would be noise; logging key codes would be a keylog (see SECURITY.md).
    var isLoggable: Bool {
        switch self {
        case .pointerMove, .pointerScroll, .ping: return false
        default: return true
        }
    }

    /// Short, content-free label for the menu bar's "last command" readout.
    /// Deliberately excludes text and key codes.
    var label: String {
        switch self {
        case .pointerMove:      return "move"
        case .pointerDown:      return "button down"
        case .pointerUp:        return "button up"
        case .pointerClick:     return "click"
        case .pointerScroll:    return "scroll"
        case .textInsert:       return "text"
        case .keyPress:         return "key"
        case .swipe(let d, let n): return "\(n)-finger swipe \(d.rawValue)"
        case .systemAction(let a): return a.rawValue
        case .shortcutRun:      return "shortcut"
        case .deckGet:          return "deck.get"
        case .deckSave:         return "deck.save"
        case .appsGet:          return "apps.get"
        case .ping:             return "ping"
        }
    }
}

/// The flat JSON envelope the browser sends. Kept permissive at the Codable
/// layer so that validation lives in one place (`Command.decode`) with precise,
/// reportable rejection reasons, rather than being spread across decoding errors.
private struct Envelope: Decodable {
    let v: Int?
    let t: String
    let dx: Double?
    let dy: Double?
    let button: String?
    let count: Int?
    let mods: [String]?
    let keyCode: Int?
    let text: String?
    let dir: String?
    let fingers: Int?
    let action: String?
    let id: String?
    let deck: String?
}

extension Command {
    static func decode(_ data: Data) throws -> Command {
        guard data.count <= Limits.maxMessageBytes else {
            throw ValidationError.tooLarge(data.count)
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ValidationError.badJSON
        }
        guard env.v == Limits.protocolVersion else {
            throw ValidationError.unsupportedVersion(env.v)
        }
        // A deck write is the one message allowed to be large; it has its own
        // bound below. Everything else is held to the much tighter command cap,
        // so the headroom a deck write needs is not available to a pointer
        // packet or an unrecognised type.
        guard env.t == "deck.save" || data.count <= Limits.maxCommandBytes else {
            throw ValidationError.tooLarge(data.count)
        }

        func delta(_ value: Double?, _ field: String, limit: Double) throws -> Double {
            guard let value else { throw ValidationError.missingField(field) }
            guard value.isFinite, abs(value) <= limit else {
                throw ValidationError.outOfRange(field, value)
            }
            return value
        }
        func button() throws -> MouseButton {
            let raw = env.button ?? "left"
            guard let b = MouseButton(rawValue: raw) else {
                throw ValidationError.badEnum("button", raw)
            }
            return b
        }
        func modifiers() throws -> [Modifier] {
            guard let raw = env.mods else { return [] }
            var seen: [Modifier] = []
            for name in raw {
                guard let m = Modifier(rawValue: name) else {
                    throw ValidationError.badEnum("mods", name)
                }
                if !seen.contains(m) { seen.append(m) }
            }
            return seen
        }

        switch env.t {
        case "pointer.move":
            return .pointerMove(dx: try delta(env.dx, "dx", limit: Limits.maxPointerDelta),
                                dy: try delta(env.dy, "dy", limit: Limits.maxPointerDelta))

        case "pointer.scroll":
            return .pointerScroll(dx: try delta(env.dx, "dx", limit: Limits.maxScrollDelta),
                                  dy: try delta(env.dy, "dy", limit: Limits.maxScrollDelta))

        case "pointer.down":
            return .pointerDown(button: try button(), mods: try modifiers())

        case "pointer.up":
            return .pointerUp

        case "pointer.click":
            let count = env.count ?? 1
            guard (1...3).contains(count) else {
                throw ValidationError.outOfRange("count", Double(count))
            }
            return .pointerClick(button: try button(), count: count, mods: try modifiers())

        case "text.insert":
            guard let text = env.text else { throw ValidationError.missingField("text") }
            guard text.utf16.count <= Limits.maxTextUTF16 else {
                throw ValidationError.textTooLong(text.utf16.count)
            }
            return .textInsert(text)

        case "key.press":
            guard let code = env.keyCode else { throw ValidationError.missingField("keyCode") }
            return .keyPress(keyCode: try KeyCodes.validate(code), mods: try modifiers())

        case "swipe":
            guard let raw = env.dir else { throw ValidationError.missingField("dir") }
            guard let dir = SwipeDirection(rawValue: raw) else {
                throw ValidationError.badEnum("dir", raw)
            }
            let fingers = env.fingers ?? 3
            guard (2...4).contains(fingers) else {
                throw ValidationError.outOfRange("fingers", Double(fingers))
            }
            return .swipe(dir, fingers: fingers)

        case "system.action":
            guard let raw = env.action else { throw ValidationError.missingField("action") }
            guard let action = SystemAction(rawValue: raw) else {
                throw ValidationError.badEnum("action", raw)
            }
            return .systemAction(action)

        case "shortcut.run":
            guard let id = env.id, !id.isEmpty else { throw ValidationError.missingField("id") }
            guard id.count <= Limits.maxShortcutIDLength else {
                throw ValidationError.outOfRange("id", Double(id.count))
            }
            return .shortcutRun(id: id)

        case "deck.get":
            return .deckGet

        case "deck.save":
            guard let deck = env.deck else { throw ValidationError.missingField("deck") }
            guard deck.utf8.count <= Limits.maxDeckBytes else {
                throw ValidationError.tooLarge(deck.utf8.count)
            }
            return .deckSave(json: deck)

        case "apps.get":
            return .appsGet

        case "ping":
            return .ping

        default:
            throw ValidationError.unknownType(env.t)
        }
    }
}

/// Token-bucket rate limiter. One instance per connection; `allow()` is called
/// on the connection's own queue so it needs no locking.
struct RateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var last: CFTimeInterval

    init(perSecond: Int = Limits.maxCommandsPerSecond) {
        capacity = Double(perSecond)
        refillPerSecond = Double(perSecond)
        tokens = Double(perSecond)
        last = CFAbsoluteTimeGetCurrent()
    }

    mutating func allow() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        tokens = min(capacity, tokens + (now - last) * refillPerSecond)
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
