import CoreGraphics
import Foundation

/// Decides what a validated command actually does.
///
/// Separate from `Helper` so routing can be exercised without an app, a menu
/// bar, or real input injection: every side effect arrives through an injected
/// closure. The integration suite points those closures at capture buffers, so
/// the tests run the real routing — including the launch allowlist — while never
/// moving the actual cursor.
final class CommandRouter {
    /// Side effects, injected so they can be captured in tests.
    struct Effects {
        var inject: (Command) -> Void
        var openURL: (URL) -> Void
        var openApplication: (URL) -> Void
        var allowedAppPaths: () -> Set<String>
        var appListJSON: () -> String
    }

    private var deck: Deck
    private let lock = NSLock()
    private let effects: Effects

    /// Content-free label for the menu bar's activity readout. Never text or key
    /// codes — logging those would amount to a keylog.
    var onActivity: ((String) -> Void)?

    init(deck: Deck, effects: Effects) {
        self.deck = deck
        self.effects = effects
    }

    var currentDeck: Deck {
        lock.lock(); defer { lock.unlock() }
        return deck
    }

    func handle(_ command: Command, respond: (String) -> Void) {
        if command.isLoggable { onActivity?(command.label) }

        switch command {
        case .ping:
            respond(Reply.pong)

        case .deckGet:
            let current = currentDeck
            // `null` rather than an empty deck, so the phone knows to seed the
            // Mac with its own defaults instead of showing nothing.
            respond(Reply.deck(current.folders.isEmpty ? "null" : DeckStore.encoded(current)))

        case .deckSave(let json):
            saveDeck(json: json, respond: respond)

        case .appsGet:
            respond(Reply.apps(effects.appListJSON()))

        case .shortcutRun(let id):
            runShortcut(id: id, respond: respond)

        default:
            effects.inject(command)
        }
    }

    private func saveDeck(json: String, respond: (String) -> Void) {
        do {
            let validated = try DeckValidator.validate(json: json,
                                                       allowedAppPaths: effects.allowedAppPaths())
            lock.lock(); deck = validated; lock.unlock()
            DeckStore.save(validated)
            respond(Reply.deckSaved)
        } catch let error as DeckError {
            NSLog("[CommandRouter] rejected deck write: %@", error.description)
            respond(Reply.error(error.description))
        } catch {
            respond(Reply.error("deck rejected"))
        }
    }

    /// Resolve a button id against the Mac's own validated deck.
    ///
    /// The target is re-validated here even though it was validated on write.
    /// That is deliberate: a hand-edited or corrupted `deck.json` on disk still
    /// cannot produce an arbitrary `open`.
    private func runShortcut(id: String, respond: (String) -> Void) {
        guard let item = currentDeck.item(id: id) else {
            respond(Reply.error("unknown shortcut"))
            return
        }

        switch item.type {
        case "shortcut":
            guard let code = item.keyCode, KeyCodes.allowed.contains(code) else {
                respond(Reply.error("shortcut key not permitted"))
                return
            }
            let mods = (item.mods ?? []).compactMap(Modifier.init(rawValue:))
            effects.inject(.keyPress(keyCode: CGKeyCode(code), mods: mods))

        case "text":
            effects.inject(.textInsert(item.text ?? ""))

        case "launch":
            let target = item.target ?? ""
            guard DeckValidator.isPermittedTarget(target, allowedAppPaths: effects.allowedAppPaths()) else {
                NSLog("[CommandRouter] refused a stored launch target")
                respond(Reply.error("target not permitted"))
                return
            }
            if target.hasPrefix("/") {
                effects.openApplication(URL(fileURLWithPath: target))
            } else if let url = URL(string: target) {
                effects.openURL(url)
            }

        default:
            respond(Reply.error("unknown item type"))
        }
    }
}