import CoreGraphics
import Foundation

// Minimal test harness. XCTest is avoided deliberately: this project builds with
// Command Line Tools only, and a hand-rolled runner keeps `./tests/run.sh`
// dependency-free. Exits non-zero on any failure.

var passed = 0
var failed = 0
var currentGroup = ""

func group(_ name: String) {
    currentGroup = name
    print("\n\(name)")
}

func check(_ label: String, _ condition: Bool) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ \(label)")
    }
}

/// Assert that decoding throws. Most validation tests are of this shape.
func rejects(_ label: String, _ json: String) {
    do {
        _ = try Command.decode(Data(json.utf8))
        failed += 1
        print("  ✗ \(label) — accepted but should have been rejected")
    } catch {
        passed += 1
        print("  ✓ \(label) — \(error)")
    }
}

func accepts(_ label: String, _ json: String, _ verify: (Command) -> Bool = { _ in true }) {
    do {
        let command = try Command.decode(Data(json.utf8))
        if verify(command) {
            passed += 1
            print("  ✓ \(label)")
        } else {
            failed += 1
            print("  ✗ \(label) — decoded but wrong value: \(command)")
        }
    } catch {
        failed += 1
        print("  ✗ \(label) — rejected: \(error)")
    }
}

// MARK: - Command validation

group("Command validation — envelope")
rejects("missing version",        #"{"t":"pointer.move","dx":1,"dy":1}"#)
rejects("wrong version",          #"{"v":2,"t":"pointer.move","dx":1,"dy":1}"#)
rejects("unknown type",           #"{"v":1,"t":"shell.exec","cmd":"rm -rf /"}"#)
rejects("malformed JSON",         #"{"v":1,"t":"#)
rejects("not an object",          #"[1,2,3]"#)
accepts("valid pointer move",     #"{"v":1,"t":"pointer.move","dx":8.5,"dy":-3}"#) { cmd in
    if case .pointerMove(let dx, let dy) = cmd { return dx == 8.5 && dy == -3 }
    return false
}

group("Command validation — bounds (reject, don't clamp)")
rejects("pointer dx over limit",  #"{"v":1,"t":"pointer.move","dx":100000,"dy":0}"#)
rejects("pointer dy over limit",  #"{"v":1,"t":"pointer.move","dx":0,"dy":-201}"#)
rejects("NaN delta",              #"{"v":1,"t":"pointer.move","dx":null,"dy":0}"#)
accepts("pointer at limit",       #"{"v":1,"t":"pointer.move","dx":200,"dy":-200}"#)
rejects("scroll over limit",      #"{"v":1,"t":"pointer.scroll","dx":0,"dy":501}"#)
accepts("scroll at limit",        #"{"v":1,"t":"pointer.scroll","dx":0,"dy":-500}"#)
rejects("click count 0",          #"{"v":1,"t":"pointer.click","button":"left","count":0}"#)
rejects("click count 99",         #"{"v":1,"t":"pointer.click","button":"left","count":99}"#)
accepts("double click",           #"{"v":1,"t":"pointer.click","button":"left","count":2}"#)
rejects("bogus button",           #"{"v":1,"t":"pointer.click","button":"middle"}"#)

group("Command validation — text")
accepts("ascii text",             #"{"v":1,"t":"text.insert","text":"hello"}"#)
accepts("emoji text",             #"{"v":1,"t":"text.insert","text":"hi 👋🏽"}"#)
do {
    let long = String(repeating: "a", count: Limits.maxTextUTF16 + 1)
    rejects("text over 256 UTF-16", #"{"v":1,"t":"text.insert","text":"\#(long)"}"#)
    let atLimit = String(repeating: "a", count: Limits.maxTextUTF16)
    accepts("text at 256 UTF-16",   #"{"v":1,"t":"text.insert","text":"\#(atLimit)"}"#)
}
do {
    // Two separate ceilings, and both must hold.
    //
    // An input command is capped tightly: a pointer packet is ~60 bytes, so a
    // 4 KB+ one is a flood or a probe either way.
    let overCommand = String(repeating: "x", count: Limits.maxCommandBytes)
    rejects("command over the 4 KB command cap",
            #"{"v":1,"t":"text.insert","text":"\#(overCommand)"}"#)

    // A deck write is exempt from that cap, because app icons are embedded as
    // base64 PNGs — but only up to its own bound.
    let roomyDeck = #"{"folders":[{"id":"f1","name":"F","items":[]}]}"#
    accepts("a deck write larger than the command cap is allowed",
            #"{"v":1,"t":"deck.save","deck":\#(JSON.string(roomyDeck)),"pad":"\#(overCommand)"}"#)

    // The exemption is for deck writes specifically, not for any large message.
    rejects("an unknown type does not inherit the deck exemption",
            #"{"v":1,"t":"nonsense","pad":"\#(overCommand)"}"#)

    // And nothing may exceed the transport ceiling.
    let overTransport = String(repeating: "x", count: Limits.maxMessageBytes + 1)
    rejects("deck write over the transport ceiling",
            #"{"v":1,"t":"deck.save","deck":"\#(overTransport)"}"#)

    // The two caps must stay ordered, or the deck limit is unreachable: this is
    // exactly the inversion that made the app picker unusable.
    check("the transport ceiling exceeds the command cap",
          Limits.maxMessageBytes > Limits.maxCommandBytes)
    check("the transport ceiling can hold a maximal deck write",
          Limits.maxMessageBytes > Limits.maxDeckBytes)
    check("a single app icon fits in a deck write",
          DeckValidator.maxIconDataURIBytes < Limits.maxDeckBytes)
}

group("Command validation — keys use an allowlist, not raw ints")
accepts("return key",             #"{"v":1,"t":"key.press","keyCode":36}"#)
accepts("cmd+c",                  #"{"v":1,"t":"key.press","keyCode":8,"mods":["command"]}"#) { cmd in
    if case .keyPress(let code, let mods) = cmd { return code == 8 && mods == [.command] }
    return false
}
rejects("key code 999",           #"{"v":1,"t":"key.press","keyCode":999}"#)
rejects("negative key code",      #"{"v":1,"t":"key.press","keyCode":-1}"#)
rejects("capslock (not allowed)", #"{"v":1,"t":"key.press","keyCode":57}"#)
rejects("bogus modifier",         #"{"v":1,"t":"key.press","keyCode":8,"mods":["hyper"]}"#)
accepts("duplicate mods dedup",   #"{"v":1,"t":"key.press","keyCode":8,"mods":["command","command"]}"#) { cmd in
    if case .keyPress(_, let mods) = cmd { return mods == [.command] }
    return false
}

group("Command validation — swipe and system actions")
accepts("3-finger left",          #"{"v":1,"t":"swipe","dir":"left","fingers":3}"#)
accepts("4-finger right",         #"{"v":1,"t":"swipe","dir":"right","fingers":4}"#)
rejects("5 fingers",              #"{"v":1,"t":"swipe","dir":"left","fingers":5}"#)
rejects("diagonal direction",     #"{"v":1,"t":"swipe","dir":"northwest","fingers":3}"#)
accepts("mission control",        #"{"v":1,"t":"system.action","action":"mission_control"}"#)
rejects("unknown action",         #"{"v":1,"t":"system.action","action":"format_disk"}"#)

group("Command validation — shortcuts carry an id, never a target")
accepts("shortcut by id",         #"{"v":1,"t":"shortcut.run","id":"xab12cd"}"#)
rejects("empty id",               #"{"v":1,"t":"shortcut.run","id":""}"#)
rejects("missing id",             #"{"v":1,"t":"shortcut.run"}"#)
// The decisive one: there is no wire form that carries an executable target.
rejects("no legacy launch type",  #"{"v":1,"t":"launch","target":"/bin/sh"}"#)

// MARK: - Rate limiting

group("Rate limiter")
do {
    var limiter = RateLimiter(perSecond: 10)
    var allowed = 0
    for _ in 0..<50 where limiter.allow() { allowed += 1 }
    check("bursts are capped at the bucket size", allowed == 10)
    check("further calls are refused", limiter.allow() == false)
}

// MARK: - Session store

group("SessionStore — pairing")
do {
    let tmp = URL(fileURLWithPath: "/tmp/remotemac-test-session-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = SessionStore(fileURL: tmp)

    check("starts with no paired devices", store.pairedDeviceCount == 0)
    check("nil token is unauthorized", store.isAuthorized(token: nil) == false)
    check("empty token is unauthorized", store.isAuthorized(token: "") == false)

    let wrongPIN = store.pin == "000000" ? "111111" : "000000"
    if case .wrongPIN = store.pair(pin: wrongPIN, label: "t") {
        check("wrong PIN is refused", true)
    } else {
        check("wrong PIN is refused", false)
    }

    guard case .success(let token) = store.pair(pin: store.pin, label: "phone") else {
        check("correct PIN mints a token", false)
        exit(1)
    }
    check("correct PIN mints a token", true)
    check("token is 256 bits of hex", token.count == 64)
    check("token authorizes", store.isAuthorized(token: token))
    check("a different token does not", store.isAuthorized(token: String(repeating: "a", count: 64)) == false)
    check("device is recorded", store.pairedDeviceCount == 1)

    // Anything derivable from the PIN is only as strong as the PIN's ~20 bits,
    // so a derived value must never authenticate on its own.
    check("a PIN-derived token is rejected",
          store.isAuthorized(token: "pin-derived-v1:" + store.pin) == false)

    store.revokeAll()
    check("revoke clears devices", store.pairedDeviceCount == 0)
    check("revoked token no longer authorizes", store.isAuthorized(token: token) == false)
}

group("SessionStore — throttling")
do {
    let tmp = URL(fileURLWithPath: "/tmp/remotemac-test-throttle-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = SessionStore(fileURL: tmp)
    let wrong = store.pin == "000000" ? "111111" : "000000"

    var sawThrottle = false
    for _ in 0..<8 {
        if case .throttled = store.pair(pin: wrong, label: "t") { sawThrottle = true; break }
    }
    check("repeated wrong PINs trigger a lockout", sawThrottle)

    // The caller is told how long to wait, which is what the HTTP layer turns
    // into a Retry-After value.
    if case .throttled(let retryAfter) = store.pair(pin: wrong, label: "t") {
        check("the lockout reports a positive wait", retryAfter > 0)
    } else {
        check("the lockout reports a positive wait", false)
    }

    // Critically, the lockout must also block the *correct* PIN, or an attacker
    // racing a legitimate pairing would be unaffected by it.
    if case .throttled = store.pair(pin: store.pin, label: "t") {
        check("lockout applies even to the correct PIN", true)
    } else {
        check("lockout applies even to the correct PIN", false)
    }

    // A new PIN is the operator's way out of a lockout they triggered.
    store.regeneratePIN()
    if case .success = store.pair(pin: store.pin, label: "t") {
        check("a new PIN clears the lockout", true)
    } else {
        check("a new PIN clears the lockout", false)
    }
}

// MARK: - Deck validation

group("Deck validation — launch targets")
do {
    let installed: Set<String> = ["/System/Applications/Mission Control.app",
                                  "/Applications/Safari.app"]
    func permitted(_ t: String) -> Bool {
        DeckValidator.isPermittedTarget(t, allowedAppPaths: installed)
    }

    check("https URL allowed",             permitted("https://www.youtube.com/"))
    check("https with path allowed",       permitted("https://mail.google.com/mail/u/0"))
    check("installed app path allowed",    permitted("/Applications/Safari.app"))
    check("Mission Control allowed",       permitted("/System/Applications/Mission Control.app"))

    check("plain http refused",            !permitted("http://example.com/"))
    check("file: refused",                 !permitted("file:///etc/passwd"))
    check("uninstalled app path refused",  !permitted("/Users/me/Evil.app"))
    check("shell binary refused",          !permitted("/bin/sh"))
    check("relative path refused",         !permitted("../../bin/sh"))
    check("custom scheme refused",         !permitted("shortcuts://run-workflow?name=x"))
    check("prefs scheme refused",          !permitted("x-apple.systempreferences:com.apple.preference"))
    check("smb refused",                   !permitted("smb://attacker/share"))
    check("javascript: refused",           !permitted("javascript:alert(1)"))
    check("empty refused",                 !permitted(""))
    check("https without host refused",    !permitted("https://"))
}

group("Deck validation — whole deck")
do {
    let installed: Set<String> = ["/Applications/Safari.app"]
    func validate(_ json: String) throws -> Deck {
        try DeckValidator.validate(json: json, allowedAppPaths: installed)
    }
    func deckRejects(_ label: String, _ json: String) {
        do { _ = try validate(json); check(label, false) }
        catch { passed += 1; print("  ✓ \(label) — \(error)") }
    }

    let good = #"""
    {"folders":[{"id":"f1","name":"Basics","items":[
      {"id":"i1","type":"shortcut","label":"Copy","keyCode":8,"mods":["command"]},
      {"id":"i2","type":"launch","label":"YouTube","target":"https://www.youtube.com/"},
      {"id":"i3","type":"text","label":"Sig","text":"regards"}
    ]}]}
    """#
    do {
        let deck = try validate(good)
        check("valid deck accepted", deck.folders.count == 1 && deck.folders[0].items.count == 3)
        check("lookup by id works", deck.item(id: "i2")?.target == "https://www.youtube.com/")
        check("unknown id returns nil", deck.item(id: "nope") == nil)
    } catch {
        check("valid deck accepted", false)
        print("    \(error)")
    }

    deckRejects("launch to /bin/sh refused",
        #"{"folders":[{"id":"f","name":"n","items":[{"id":"i","type":"launch","label":"x","target":"/bin/sh"}]}]}"#)
    deckRejects("launch to file: refused",
        #"{"folders":[{"id":"f","name":"n","items":[{"id":"i","type":"launch","label":"x","target":"file:///etc/passwd"}]}]}"#)
    deckRejects("bad key code refused",
        #"{"folders":[{"id":"f","name":"n","items":[{"id":"i","type":"shortcut","label":"x","keyCode":9999}]}]}"#)
    deckRejects("bad modifier refused",
        #"{"folders":[{"id":"f","name":"n","items":[{"id":"i","type":"shortcut","label":"x","keyCode":8,"mods":["root"]}]}]}"#)
    deckRejects("unknown item type refused",
        #"{"folders":[{"id":"f","name":"n","items":[{"id":"i","type":"macro","label":"x"}]}]}"#)
    deckRejects("path-like id refused",
        #"{"folders":[{"id":"../../etc","name":"n","items":[]}]}"#)
    deckRejects("not JSON", "definitely not json")

    do {
        let folders = (0..<(Limits.maxDeckFolders + 1))
            .map { #"{"id":"f\#($0)","name":"n","items":[]}"# }
            .joined(separator: ",")
        deckRejects("too many folders refused", #"{"folders":[\#(folders)]}"#)
    }
    do {
        let items = (0..<(Limits.maxDeckItemsPerFolder + 1))
            .map { #"{"id":"i\#($0)","type":"shortcut","label":"x","keyCode":8}"# }
            .joined(separator: ",")
        deckRejects("too many items refused", #"{"folders":[{"id":"f","name":"n","items":[\#(items)]}]}"#)
    }

    // Normalisation: unknown keys the phone sent must not survive into storage.
    do {
        let sneaky = #"{"folders":[{"id":"f","name":"n","items":[{"id":"i","type":"shortcut","label":"x","keyCode":8,"target":"/bin/sh"}]}]}"#
        let deck = try validate(sneaky)
        check("stray target dropped from a shortcut item", deck.item(id: "i")?.target == nil)
    } catch {
        check("stray target dropped from a shortcut item", false)
    }
}

// MARK: - Grapheme chunking

group("Text chunking never splits a grapheme")
do {
    func chunks(_ s: String, _ n: Int) -> [String] {
        EventInjector.graphemeChunks(s, maxUTF16: n)
    }

    check("empty string yields nothing", chunks("", 16).isEmpty)
    check("short ascii is one chunk", chunks("hello", 16) == ["hello"])
    check("reassembles exactly", chunks("hello world, this is longer", 8).joined() == "hello world, this is longer")

    // A family emoji is one grapheme but many UTF-16 units; it must not be cut.
    let family = "👨‍👩‍👧‍👦"
    check("family emoji is one grapheme", family.count == 1)
    check("family emoji exceeds the chunk cap", family.utf16.count > 8)
    check("oversized grapheme emitted whole", chunks(family, 8) == [family])

    let mixed = "a👨‍👩‍👧‍👦b"
    let out = chunks(mixed, 8)
    check("mixed text reassembles", out.joined() == mixed)
    check("every chunk is whole graphemes", out.allSatisfy { chunk in
        chunk.unicodeScalars.first.map { !$0.properties.isJoinControl } ?? true
    })

    // Skin-tone and combining sequences are the other common breakage.
    check("skin tone modifier stays attached", chunks("👋🏽", 2) == ["👋🏽"])
    check("combining accent stays attached", chunks("e\u{0301}", 1) == ["e\u{0301}"])

    check("chunks respect the cap when they can", chunks(String(repeating: "a", count: 20), 8)
        .allSatisfy { $0.utf16.count <= 8 })
}

// MARK: - Origin and Host policy

group("Origin / Host policy")
do {
    let origins = NetworkInfo.acceptableOrigins(httpPort: 8765)
    check("localhost origin accepted", origins.contains("http://localhost:8765"))
    check("attacker origin not accepted", !origins.contains("http://evil.example"))
    check("control port is not a valid page origin", !origins.contains("http://localhost:8766"))
    check("https variant not silently accepted", !origins.contains("https://localhost:8765"))

    let hosts = NetworkInfo.acceptableHosts(httpPort: 8765)
    check("localhost host accepted", hosts.contains("localhost:8765"))
    check("bare localhost accepted", hosts.contains("localhost"))
    check("rebinding host refused", !hosts.contains("evil.example"))
}

// MARK: - Installed application list

// This exists because the picker was silently empty: the payload builder was
// never called, so the Mac answered `apps.get` with `[]` and the deck editor
// showed no apps at all. Nothing failed, nothing logged, and no test noticed —
// so the test is about the payload actually being built.
group("Installed application list")
do {
    let allowed = AppList.allowedPaths()
    check("the allowlist is populated", !allowed.isEmpty)
    check("it contains a known system app", allowed.contains("/System/Applications/Utilities/Terminal.app"))
    check("a non-application path is not in it", !allowed.contains("/bin/sh"))
    check("an arbitrary bundle path is not in it", !allowed.contains("/Users/nobody/evil.app"))

    let json = AppList.json()
    check("the picker payload is not the empty list", json != "[]" && !json.isEmpty)

    let decoded = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]]
    let apps = decoded ?? nil
    check("it decodes as an array of objects", apps != nil)
    check("it is not empty", (apps?.count ?? 0) > 0)

    if let first = apps?.first {
        check("each entry has a name", !(first["name"] ?? "").isEmpty)
        check("each entry has a path", (first["path"] ?? "").hasPrefix("/"))
    } else {
        check("each entry has a name", false)
        check("each entry has a path", false)
    }

    // Every path offered to the picker must also pass the launch allowlist, or
    // the editor would let you build a button the Mac then refuses to run.
    let paths = Set((apps ?? []).compactMap { $0["path"] })
    check("every listed app is a permitted launch target",
          !paths.isEmpty && paths.allSatisfy {
              DeckValidator.isPermittedTarget($0, allowedAppPaths: allowed)
          })

    // Icons are embedded in the response, so the one format the client renders
    // is the only one that may appear.
    let icons = (apps ?? []).compactMap { $0["icon"] }.filter { !$0.isEmpty }
    check("at least one icon was rendered", !icons.isEmpty)
    check("icons are base64 PNG data URIs only",
          icons.allSatisfy { $0.hasPrefix("data:image/png;base64,") })
    check("every icon survives deck validation",
          icons.allSatisfy { (try? DeckValidator.validate(icon: $0)) != nil })

    check("the result is cached, not rebuilt", AppList.json() == json)
}

// MARK: - Summary

print("\n" + String(repeating: "─", count: 46))
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
