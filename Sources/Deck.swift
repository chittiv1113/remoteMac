import Foundation

/// The shortcut deck: the Mac's authoritative list of what a button may do.
///
/// The phone may *edit* the deck, but every write is parsed and validated on the
/// Mac before it is stored, and pressing a button sends only its **id**. A
/// target string is never accepted at run time, so there is no path from a
/// WebSocket message to an arbitrary `open` — which is the whole reason the deck
/// is modelled here rather than trusted from the client.
struct Deck: Codable, Equatable {
    var folders: [Folder]

    struct Folder: Codable, Equatable {
        var id: String
        var name: String
        var items: [Item]
    }

    struct Item: Codable, Equatable {
        var id: String
        var type: String
        var label: String
        var keyCode: Int?
        var mods: [String]?
        var text: String?
        var target: String?
        var icon: String?
        var color: String?
    }

    func item(id: String) -> Item? {
        for folder in folders {
            if let hit = folder.items.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    static let empty = Deck(folders: [])
}

enum DeckError: Error, CustomStringConvertible {
    case badJSON
    case tooLarge(Int)
    case tooManyFolders(Int)
    case tooManyItems(Int)
    case badID(String)
    case badLabel
    case unknownItemType(String)
    case badKeyCode(Int)
    case badModifier(String)
    case textTooLong(Int)
    case badTarget(String)
    case badIcon
    case badColor(String)

    var description: String {
        switch self {
        case .badJSON:                 return "deck is not valid JSON"
        case .tooLarge(let n):         return "deck too large (\(n) bytes)"
        case .tooManyFolders(let n):   return "too many folders (\(n))"
        case .tooManyItems(let n):     return "too many items in a folder (\(n))"
        case .badID(let id):           return "invalid id '\(id)'"
        case .badLabel:                return "invalid label"
        case .unknownItemType(let t):  return "unknown item type '\(t)'"
        case .badKeyCode(let c):       return "key code \(c) is not in the allowlist"
        case .badModifier(let m):      return "unknown modifier '\(m)'"
        case .textTooLong(let n):      return "item text too long (\(n))"
        case .badTarget(let t):        return "target not permitted: \(t)"
        case .badIcon:                return "icon must be a short emoji or a data:image/png;base64 URI"
        case .badColor(let c):        return "colour must be a hex literal, got '\(c)'"
        }
    }
}

enum DeckValidator {
    static let maxLabelLength = 32
    static let maxNameLength = 24

    /// Parse, validate and normalise. Returns the clean deck, or throws.
    ///
    /// Normalising matters: the stored form is re-encoded from the validated
    /// model, so unknown or extra JSON keys the phone sent are dropped rather
    /// than persisted and handed back out.
    static func validate(json: String, allowedAppPaths: Set<String>) throws -> Deck {
        guard json.utf8.count <= Limits.maxDeckBytes else {
            throw DeckError.tooLarge(json.utf8.count)
        }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Deck.self, from: data) else {
            throw DeckError.badJSON
        }
        guard decoded.folders.count <= Limits.maxDeckFolders else {
            throw DeckError.tooManyFolders(decoded.folders.count)
        }

        var folders: [Deck.Folder] = []
        for folder in decoded.folders {
            guard isValidID(folder.id) else { throw DeckError.badID(folder.id) }
            guard folder.items.count <= Limits.maxDeckItemsPerFolder else {
                throw DeckError.tooManyItems(folder.items.count)
            }
            let name = String(folder.name.prefix(maxNameLength))
            var items: [Deck.Item] = []
            for item in folder.items {
                items.append(try validate(item: item, allowedAppPaths: allowedAppPaths))
            }
            folders.append(Deck.Folder(id: folder.id, name: name, items: items))
        }
        return Deck(folders: folders)
    }

    private static func validate(item: Deck.Item, allowedAppPaths: Set<String>) throws -> Deck.Item {
        guard isValidID(item.id) else { throw DeckError.badID(item.id) }
        guard item.label.count <= maxLabelLength else { throw DeckError.badLabel }
        let icon = try validate(icon: item.icon)
        let color = try validate(color: item.color)

        switch item.type {
        case "shortcut":
            guard let code = item.keyCode else { throw DeckError.badKeyCode(-1) }
            guard KeyCodes.allowed.contains(code) else { throw DeckError.badKeyCode(code) }
            let mods = try normalise(mods: item.mods)
            return Deck.Item(id: item.id, type: "shortcut", label: item.label,
                             keyCode: code, mods: mods, text: nil, target: nil,
                             icon: icon, color: color)

        case "text":
            let text = item.text ?? ""
            guard text.utf16.count <= Limits.maxTextUTF16 else {
                throw DeckError.textTooLong(text.utf16.count)
            }
            return Deck.Item(id: item.id, type: "text", label: item.label,
                             keyCode: nil, mods: nil, text: text, target: nil,
                             icon: icon, color: color)

        case "launch":
            let target = item.target ?? ""
            guard isPermittedTarget(target, allowedAppPaths: allowedAppPaths) else {
                throw DeckError.badTarget(target)
            }
            return Deck.Item(id: item.id, type: "launch", label: item.label,
                             keyCode: nil, mods: nil, text: nil, target: target,
                             icon: icon, color: color)

        default:
            throw DeckError.unknownItemType(item.type)
        }
    }

    static let maxIconDataURIBytes = 16 * 1024

    /// An icon is either a short literal (an emoji) or a base64 PNG data URI.
    ///
    /// The data URI form is checked strictly — correct prefix, base64 alphabet
    /// only, bounded length. Without that, a stored `icon` reaching the client's
    /// `<img src>` could be an arbitrary URL, which would both break the page's
    /// no-external-requests property and leak that the deck was opened.
    static func validate(icon: String?) throws -> String? {
        guard let icon, !icon.isEmpty else { return nil }

        if icon.hasPrefix("data:") {
            let prefix = "data:image/png;base64,"
            guard icon.hasPrefix(prefix), icon.utf8.count <= maxIconDataURIBytes else {
                throw DeckError.badIcon
            }
            let payload = icon.dropFirst(prefix.count)
            guard !payload.isEmpty, payload.allSatisfy({
                $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "="
            }) else { throw DeckError.badIcon }
            return icon
        }

        // Emoji / short glyph. Grapheme count, so a ZWJ sequence counts as one.
        guard icon.count <= 4 else { throw DeckError.badIcon }
        return icon
    }

    /// Colours are written into `style.background` by the client, so only hex
    /// literals are accepted. A free-form CSS value could carry `url(...)` and
    /// turn a deck button into an outbound request.
    static func validate(color: String?) throws -> String? {
        guard let color, !color.isEmpty else { return nil }
        guard color.hasPrefix("#") else { throw DeckError.badColor(color) }
        let digits = color.dropFirst()
        guard [3, 4, 6, 8].contains(digits.count),
              digits.allSatisfy({ $0.isHexDigit }) else { throw DeckError.badColor(color) }
        return color
    }

    private static func normalise(mods: [String]?) throws -> [String] {
        guard let mods else { return [] }
        var out: [String] = []
        for name in mods {
            guard Modifier(rawValue: name) != nil else { throw DeckError.badModifier(name) }
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// ids are generated by the client (`"x" + base36`), so keep the charset tight
    /// and reject anything that could be mistaken for a path or a separator.
    static func isValidID(_ id: String) -> Bool {
        guard (1...Limits.maxShortcutIDLength).contains(id.count) else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// A launch target is permitted only if it is an `https:` URL, or the path of
    /// an application the Mac actually has installed.
    ///
    /// Everything else is refused: `file:`, `http:`, custom app schemes, and any
    /// path that is not in the enumerated application set. That last point is what
    /// stops `/Users/me/evil.app` or `/bin/sh` being used as a target.
    static func isPermittedTarget(_ target: String, allowedAppPaths: Set<String>) -> Bool {
        if target.hasPrefix("/") {
            return allowedAppPaths.contains(target)
        }
        guard let url = URL(string: target), let scheme = url.scheme?.lowercased() else {
            return false
        }
        guard scheme == "https" else { return false }
        return url.host != nil
    }
}

/// Persists the validated deck. Only ever written from the validated model, so
/// the file on disk cannot contain a target the validator would reject.
enum DeckStore {
    /// Where persistent state lives, created once on first use.
    /// `REMOTEMAC_STATE_DIR` redirects it, which is what keeps the test suites
    /// from writing over a real user's deck.
    static let stateDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment["REMOTEMAC_STATE_DIR"]
        let base = environment.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("remoteMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static var fileURL: URL { stateDirectory.appendingPathComponent("deck.json") }

    static func load() -> Deck? {
        guard let data = try? Data(contentsOf: fileURL),
              let deck = try? JSONDecoder().decode(Deck.self, from: data) else { return nil }
        return deck
    }

    static func save(_ deck: Deck) {
        guard let data = try? JSONEncoder().encode(deck) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func encoded(_ deck: Deck) -> String {
        guard let data = try? JSONEncoder().encode(deck),
              let string = String(data: data, encoding: .utf8) else { return "null" }
        return string
    }
}
