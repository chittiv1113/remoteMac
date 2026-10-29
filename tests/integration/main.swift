import Darwin
import Foundation

// Integration tests: boot the real StaticHTTPServer and ControlSocket on test
// ports and drive them over actual TCP.
//
// The client is hand-rolled on POSIX sockets rather than URLSession so the test
// controls every byte — URLSession refuses to let you set Host, and no HTTP
// library will send a deliberately malformed WebSocket frame. That control is
// the point: the frame-level cases below are the ones a well-behaved client
// library makes impossible to write.
//
// Input is never injected. `control.onCommand` is captured by the test, so the
// real cursor and keyboard are untouched.

// A test that deliberately provokes a server-side close will otherwise be
// killed by SIGPIPE mid-write, taking the buffered results with it.
signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)

let HTTP_PORT: UInt16 = 18765
let WS_PORT: UInt16 = 18766

var passed = 0, failed = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ \(label)\(detail.isEmpty ? "" : " — " + detail)")
    }
}
func group(_ name: String) { print("\n\(name)") }

// MARK: - Raw TCP

func tcpConnect(port: UInt16, timeout: Int = 3) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let result = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else { close(fd); return nil }

    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

func send(_ fd: Int32, _ bytes: [UInt8]) {
    var sent = 0
    bytes.withUnsafeBufferPointer { buffer in
        while sent < bytes.count {
            let n = write(fd, buffer.baseAddress! + sent, bytes.count - sent)
            if n <= 0 { break }
            sent += n
        }
    }
}
func send(_ fd: Int32, _ string: String) { send(fd, Array(string.utf8)) }

/// Read until the peer closes or the timeout fires.
func readAll(_ fd: Int32) -> [UInt8] {
    var out = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        out.append(contentsOf: chunk[0..<n])
    }
    return out
}

/// Read at most one bufferful — for cases where the peer keeps the socket open.
let readChunkBytes = 8192

func readSome(_ fd: Int32) -> [UInt8] {
    var chunk = [UInt8](repeating: 0, count: readChunkBytes)
    let n = read(fd, &chunk, chunk.count)
    return n > 0 ? Array(chunk[0..<n]) : []
}

// MARK: - HTTP

struct HTTPResponse {
    let status: Int
    let body: String
    let raw: String
}

func httpRequest(_ method: String, _ path: String,
                 host: String? = "127.0.0.1:18765",
                 origin: String? = nil,
                 body: String? = nil) -> HTTPResponse? {
    guard let fd = tcpConnect(port: HTTP_PORT) else { return nil }
    defer { close(fd) }

    var request = "\(method) \(path) HTTP/1.1\r\n"
    if let host { request += "Host: \(host)\r\n" }
    if let origin { request += "Origin: \(origin)\r\n" }
    if let body {
        request += "Content-Type: application/x-www-form-urlencoded\r\n"
        request += "Content-Length: \(body.utf8.count)\r\n"
    }
    request += "Connection: close\r\n\r\n"
    if let body { request += body }

    send(fd, request)
    let raw = String(decoding: readAll(fd), as: UTF8.self)
    guard let firstLine = raw.components(separatedBy: "\r\n").first else { return nil }
    let parts = firstLine.split(separator: " ")
    let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
    let payload = raw.range(of: "\r\n\r\n").map { String(raw[$0.upperBound...]) } ?? ""
    return HTTPResponse(status: status, body: payload, raw: raw)
}

// MARK: - WebSocket

/// Minimal client-side WebSocket, enough to exercise the server's policy and to
/// send frames no real library would produce.
final class WSClient {
    let fd: Int32
    var handshake = ""
    private var buffer = [UInt8]()

    init?(origin: String?, host: String = "127.0.0.1:18766") {
        guard let fd = tcpConnect(port: WS_PORT) else { return nil }
        self.fd = fd

        var request = "GET / HTTP/1.1\r\n"
        request += "Host: \(host)\r\n"
        request += "Upgrade: websocket\r\n"
        request += "Connection: Upgrade\r\n"
        request += "Sec-WebSocket-Version: 13\r\n"
        request += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        if let origin { request += "Origin: \(origin)\r\n" }
        request += "\r\n"
        send(fd, request)

        // The handshake response arrives before any frames.
        let first = readSome(fd)
        let text = String(decoding: first, as: UTF8.self)
        handshake = text.components(separatedBy: "\r\n").first ?? ""
        if let marker = text.range(of: "\r\n\r\n") {
            // Anything after the headers is already-framed data.
            let consumed = text[..<marker.upperBound].utf8.count
            if first.count > consumed { buffer.append(contentsOf: first[consumed...]) }
        }
    }

    var accepted: Bool { handshake.contains("101") }

    func close() { Darwin.close(fd) }

    func sendText(_ string: String) { sendFrame(opcode: 0x1, payload: Array(string.utf8)) }

    func sendJSON(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        sendText(String(decoding: data, as: UTF8.self))
    }

    /// Correctly masked client frame, as RFC 6455 requires.
    func sendFrame(opcode: UInt8, payload: [UInt8]) {
        var frame: [UInt8] = [0x80 | opcode]
        let mask: [UInt8] = [0x1a, 0x2b, 0x3c, 0x4d]
        let n = payload.count
        if n < 126 {
            frame.append(0x80 | UInt8(n))
        } else if n < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((n >> 8) & 0xff)); frame.append(UInt8(n & 0xff))
        } else {
            frame.append(0x80 | 127)
            for i in (0..<8).reversed() { frame.append(UInt8((n >> (8 * i)) & 0xff)) }
        }
        frame.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() { frame.append(byte ^ mask[i % 4]) }
        send(fd, frame)
    }

    /// Raw bytes, bypassing framing entirely. For hostile input.
    func sendRaw(_ bytes: [UInt8]) { send(fd, bytes) }

    /// Next server text frame as a string, or nil on timeout/close.
    ///
    /// The read bound is derived from the transport ceiling rather than being a
    /// round number: the `apps` response is a few hundred kilobytes, and an
    /// 8 KB-per-read loop with a small iteration count gives up partway
    /// through it and looks exactly like the server never replied.
    func receiveText() -> String? {
        let maxReads = Limits.maxMessageBytes / readChunkBytes + 16
        for _ in 0..<maxReads {
            if let frame = popFrame() {
                if frame.opcode == 0x8 { return nil }          // close
                if frame.opcode == 0x1 {
                    return String(decoding: frame.payload, as: UTF8.self)
                }
                continue                                        // ping/pong/binary
            }
            // An empty read means the receive timeout elapsed or the peer
            // closed; either way there is no frame coming.
            let more = readSome(fd)
            if more.isEmpty { return nil }
            buffer.append(contentsOf: more)
        }
        return nil
    }

    /// Wait for a text frame whose JSON "t" matches, skipping others.
    func waitFor(type: String, attempts: Int = 6) -> [String: Any]? {
        for _ in 0..<attempts {
            guard let text = receiveText() else { return nil }
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if object["t"] as? String == type { return object }
        }
        return nil
    }

    private func popFrame() -> (opcode: UInt8, payload: [UInt8])? {
        guard buffer.count >= 2 else { return nil }
        let opcode = buffer[0] & 0x0F
        let masked = (buffer[1] & 0x80) != 0
        var length = Int(buffer[1] & 0x7F)
        var index = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = (Int(buffer[2]) << 8) | Int(buffer[3]); index = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = 0
            for i in 2..<10 { length = (length << 8) | Int(buffer[i]) }
            index = 10
        }
        if masked { index += 4 }
        guard length >= 0, buffer.count >= index + length else { return nil }
        let payload = Array(buffer[index ..< index + length])
        buffer.removeFirst(index + length)
        return (opcode, payload)
    }
}

// MARK: - Boot the real servers

let sessionFile = URL(fileURLWithPath: "/tmp/remotemac-integration-\(UUID().uuidString).json")
let sessions = SessionStore(fileURL: sessionFile)
let http = StaticHTTPServer(port: HTTP_PORT, controlPort: WS_PORT, sessions: sessions)
let control = ControlSocket(port: WS_PORT, httpPort: HTTP_PORT, sessions: sessions)

/// Side effects, captured rather than performed. The real CommandRouter runs —
/// including deck validation and the launch allowlist — but `inject` appends to a
/// buffer instead of synthesizing events, so the suite never moves the cursor or
/// opens an application.
let captureLock = NSLock()
var captured: [String] = []
var openedURLs: [String] = []
var openedApps: [String] = []

func record(_ label: String) {
    captureLock.lock(); captured.append(label); captureLock.unlock()
}
func takeCaptured() -> [String] {
    captureLock.lock(); let all = captured; captured = []; captureLock.unlock()
    return all
}
func takeOpened() -> (urls: [String], apps: [String]) {
    captureLock.lock()
    let result = (openedURLs, openedApps)
    openedURLs = []; openedApps = []
    captureLock.unlock()
    return result
}

/// A stand-in for the installed-application set, so launch validation is
/// deterministic rather than depending on what this Mac happens to have.
let fakeInstalledApps: Set<String> = ["/Applications/Safari.app",
                                      "/System/Applications/Mission Control.app"]

/// The `apps.get` payload. A stub for most of the suite, swapped for the real
/// enumeration in the app-picker group so the actual response size is exercised.
let appListLock = NSLock()
var appListPayload = "[]"
func setAppListPayload(_ json: String) {
    appListLock.lock(); appListPayload = json; appListLock.unlock()
}
func currentAppListPayload() -> String {
    appListLock.lock(); defer { appListLock.unlock() }
    return appListPayload
}

let router = CommandRouter(
    deck: .empty,
    effects: CommandRouter.Effects(
        inject: { record($0.label) },
        openURL: { url in
            captureLock.lock(); openedURLs.append(url.absoluteString); captureLock.unlock()
        },
        openApplication: { url in
            captureLock.lock(); openedApps.append(url.path); captureLock.unlock()
        },
        allowedAppPaths: { fakeInstalledApps },
        appListJSON: { currentAppListPayload() }
    )
)

control.onCommand = { command, controller in
    router.handle(command) { controller.send(json: $0) }
}

do {
    try http.start()
    try control.start()
} catch {
    print("FATAL: could not start test servers: \(error)")
    exit(1)
}
Thread.sleep(forTimeInterval: 0.4)
defer { try? FileManager.default.removeItem(at: sessionFile) }

let ORIGIN = "http://127.0.0.1:18765"

/// After every hostile input, confirm the process is still serving. A crash
/// would make this fail, which is the whole reason the frame parser is Apple's.
func serverIsAlive() -> Bool {
    httpRequest("GET", "/")?.status == 200
}

// MARK: - HTTP

group("HTTP — static assets")
check("GET / serves the app", httpRequest("GET", "/")?.status == 200)
check("the page is the remoteMac client",
      httpRequest("GET", "/")?.body.contains("remoteMac") == true)
check("GET /app.js", httpRequest("GET", "/app.js")?.status == 200)
// Regression: logic.js was added late and would 404 if left out of the route table.
check("GET /logic.js", httpRequest("GET", "/logic.js")?.status == 200)
check("GET /style.css", httpRequest("GET", "/style.css")?.status == 200)
check("GET /manifest.webmanifest", httpRequest("GET", "/manifest.webmanifest")?.status == 200)
check("unknown path 404s", httpRequest("GET", "/nope")?.status == 404)
check("no-store on assets",
      httpRequest("GET", "/")?.raw.lowercased().contains("cache-control: no-store") == true)
check("nosniff header present",
      httpRequest("GET", "/")?.raw.lowercased().contains("x-content-type-options: nosniff") == true)
check("framing denied",
      httpRequest("GET", "/")?.raw.lowercased().contains("x-frame-options: deny") == true)

group("HTTP — path traversal")
for attempt in ["/../../../etc/passwd", "/..%2f..%2fetc/passwd", "//etc/passwd",
                "/app.js/../../../etc/passwd", "/./././etc/passwd"] {
    let status = httpRequest("GET", attempt)?.status ?? 0
    check("traversal refused: \(attempt)", status == 404, "got \(status)")
}

group("HTTP — Host validation (the DNS-rebinding gate)")
check("attacker Host refused", httpRequest("GET", "/", host: "evil.example")?.status == 421)
check("attacker Host with port refused",
      httpRequest("GET", "/", host: "evil.example:18765")?.status == 421)
check("missing Host refused", httpRequest("GET", "/", host: nil)?.status == 421)
check("localhost accepted", httpRequest("GET", "/", host: "localhost:18765")?.status == 200)
check("loopback IP accepted", httpRequest("GET", "/", host: "127.0.0.1:18765")?.status == 200)

group("HTTP — method policy")
check("PUT refused", httpRequest("PUT", "/", body: "x")?.status == 405)
check("DELETE refused", httpRequest("DELETE", "/")?.status == 405)

group("HTTP — pairing")
let realPIN = sessions.pin
let wrongPIN = realPIN == "000000" ? "111111" : "000000"

check("wrong PIN is 401",
      httpRequest("POST", "/pair", origin: ORIGIN, body: "pin=\(wrongPIN)")?.status == 401)
check("cross-origin pairing is 403",
      httpRequest("POST", "/pair", origin: "http://evil.example", body: "pin=\(realPIN)")?.status == 403)
check("missing pin field is 401",
      httpRequest("POST", "/pair", origin: ORIGIN, body: "nothing=1")?.status == 401)

var token = ""
if let response = httpRequest("POST", "/pair", origin: ORIGIN, body: "pin=\(realPIN)"),
   response.status == 200,
   let data = response.body.data(using: .utf8),
   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let issued = object["token"] as? String {
    token = issued
    check("correct PIN returns a token", true)
    check("token is 256 bits of hex", issued.count == 64)
} else {
    check("correct PIN returns a token", false)
}

group("HTTP — PIN throttling")
do {
    var sawThrottle = false
    for _ in 0..<10 {
        if httpRequest("POST", "/pair", origin: ORIGIN, body: "pin=\(wrongPIN)")?.status == 429 {
            sawThrottle = true; break
        }
    }
    check("repeated wrong PINs eventually 429", sawThrottle)
    // The lockout must cover the correct PIN too, else an attacker racing a
    // legitimate pairing attempt is unaffected by it.
    check("lockout also blocks the correct PIN",
          httpRequest("POST", "/pair", origin: ORIGIN, body: "pin=\(realPIN)")?.status == 429)
}
// Clear the lockout so the WebSocket tests can proceed with a fresh token.
sessions.regeneratePIN()
if let response = httpRequest("POST", "/pair", origin: ORIGIN, body: "pin=\(sessions.pin)"),
   let data = response.body.data(using: .utf8),
   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let issued = object["token"] as? String {
    token = issued
}
check("a new PIN pairs again after lockout", !token.isEmpty)

// MARK: - WebSocket

group("WebSocket — Origin gate (anti cross-site hijacking)")
do {
    let evil = WSClient(origin: "http://evil.example")
    check("attacker Origin is rejected at handshake", evil?.accepted == false,
          "handshake: \(evil?.handshake ?? "nil")")
    evil?.close()

    let none = WSClient(origin: nil)
    check("absent Origin is rejected", none?.accepted == false)
    none?.close()

    let nullOrigin = WSClient(origin: "null")
    check("Origin: null (file:// page) is rejected", nullOrigin?.accepted == false)
    nullOrigin?.close()

    let httpsOrigin = WSClient(origin: "https://127.0.0.1:18765")
    check("https variant of our own origin is rejected", httpsOrigin?.accepted == false)
    httpsOrigin?.close()

    let good = WSClient(origin: ORIGIN)
    check("the page's own Origin is accepted", good?.accepted == true)
    good?.close()
}

group("WebSocket — authentication gate")
do {
    guard let client = WSClient(origin: ORIGIN), client.accepted else {
        check("handshake for auth tests", false); exit(1)
    }
    check("server asks for auth first", client.waitFor(type: "auth.required") != nil)

    // A command before authenticating must not be executed.
    client.sendJSON(["v": 1, "t": "pointer.move", "dx": 5, "dy": 5])
    let failed = client.waitFor(type: "auth.failed")
    check("a command sent before auth is refused", failed != nil)
    check("and nothing was dispatched", takeCaptured().isEmpty)
    client.close()
}

do {
    guard let client = WSClient(origin: ORIGIN), client.accepted else {
        check("handshake for bad-token test", false); exit(1)
    }
    _ = client.waitFor(type: "auth.required")
    client.sendJSON(["v": 1, "t": "auth", "token": String(repeating: "a", count: 64)])
    check("a wrong token is refused", client.waitFor(type: "auth.failed") != nil)
    client.close()
}

do {
    guard let client = WSClient(origin: ORIGIN), client.accepted else {
        check("handshake for legacy-token test", false); exit(1)
    }
    _ = client.waitFor(type: "auth.required")
    // A token anyone could compute from the PIN must not authenticate, or the
    // 256-bit session token would be decoration over a 20-bit secret.
    client.sendJSON(["v": 1, "t": "auth", "token": "pin-derived-v1:" + sessions.pin])
    check("a PIN-derived token is refused", client.waitFor(type: "auth.failed") != nil)
    client.close()
}

group("WebSocket — authenticated session")
var authedClient: WSClient?
do {
    guard let client = WSClient(origin: ORIGIN), client.accepted else {
        check("handshake for session tests", false); exit(1)
    }
    _ = client.waitFor(type: "auth.required")
    client.sendJSON(["v": 1, "t": "auth", "token": token])
    check("a valid token is welcomed", client.waitFor(type: "welcome") != nil)

    _ = takeCaptured()
    client.sendJSON(["v": 1, "t": "pointer.move", "dx": 8.5, "dy": -3])
    Thread.sleep(forTimeInterval: 0.25)
    check("a valid pointer.move is dispatched", takeCaptured() == ["move"])

    client.sendJSON(["v": 1, "t": "key.press", "keyCode": 36])
    Thread.sleep(forTimeInterval: 0.25)
    check("a valid key.press is dispatched", takeCaptured() == ["key"])

    client.sendJSON(["v": 1, "t": "ping"])
    check("ping is answered", client.waitFor(type: "pong") != nil)

    authedClient = client
}

group("WebSocket — validation is enforced on the wire")
do {
    guard let client = authedClient else { check("have an authed client", false); exit(1) }

    func rejected(_ label: String, _ object: [String: Any]) {
        _ = takeCaptured()
        client.sendJSON(object)
        let error = client.waitFor(type: "error")
        Thread.sleep(forTimeInterval: 0.15)
        let dispatched = takeCaptured()
        check(label, error != nil && dispatched.isEmpty,
              error == nil ? "no error returned" : "dispatched \(dispatched)")
    }

    rejected("key code outside the allowlist", ["v": 1, "t": "key.press", "keyCode": 999])
    rejected("pointer delta over the bound", ["v": 1, "t": "pointer.move", "dx": 99999, "dy": 0])
    rejected("scroll over the bound", ["v": 1, "t": "pointer.scroll", "dx": 0, "dy": 9999])
    rejected("unknown command type", ["v": 1, "t": "shell.exec", "cmd": "whoami"])
    rejected("legacy launch command is gone", ["v": 1, "t": "launch", "target": "/bin/sh"])
    rejected("wrong protocol version", ["v": 99, "t": "pointer.move", "dx": 1, "dy": 1])
    rejected("bogus modifier", ["v": 1, "t": "key.press", "keyCode": 8, "mods": ["root"]])

    // Text at and over the cap.
    _ = takeCaptured()
    client.sendJSON(["v": 1, "t": "text.insert", "text": String(repeating: "a", count: 256)])
    Thread.sleep(forTimeInterval: 0.2)
    check("text at the cap is accepted", takeCaptured() == ["text"])
    rejected("text over the cap", ["v": 1, "t": "text.insert", "text": String(repeating: "a", count: 300)])
}

group("WebSocket — deck writes are validated on the Mac")
do {
    guard let client = authedClient else { check("have an authed client", false); exit(1) }

    func saveDeck(_ json: String) -> [String: Any]? {
        let escaped = json
        client.sendJSON(["v": 1, "t": "deck.save", "deck": escaped])
        for _ in 0..<6 {
            guard let text = client.receiveText() else { return nil }
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let t = object["t"] as? String, t == "deck.saved" || t == "error" { return object }
        }
        return nil
    }

    // A deck whose launch target is a shell binary must be refused outright.
    let evilDeck = #"{"folders":[{"id":"f1","name":"n","items":[{"id":"evil","type":"launch","label":"x","target":"/bin/sh"}]}]}"#
    check("a deck containing /bin/sh is refused",
          (saveDeck(evilDeck)?["t"] as? String) == "error")

    let fileDeck = #"{"folders":[{"id":"f1","name":"n","items":[{"id":"evil2","type":"launch","label":"x","target":"file:///etc/passwd"}]}]}"#
    check("a deck containing file:// is refused",
          (saveDeck(fileDeck)?["t"] as? String) == "error")

    let badKeyDeck = #"{"folders":[{"id":"f1","name":"n","items":[{"id":"bk","type":"shortcut","label":"x","keyCode":9999}]}]}"#
    check("a deck with an out-of-allowlist key is refused",
          (saveDeck(badKeyDeck)?["t"] as? String) == "error")

    let cssDeck = #"{"folders":[{"id":"f1","name":"n","items":[{"id":"c1","type":"shortcut","label":"x","keyCode":8,"color":"url(http://evil/x)"}]}]}"#
    check("a deck with a non-hex colour is refused",
          (saveDeck(cssDeck)?["t"] as? String) == "error")

    // A legitimate deck is accepted and becomes the Mac's copy.
    let goodDeck = #"{"folders":[{"id":"f1","name":"Basics","items":[{"id":"copy","type":"shortcut","label":"Copy","keyCode":8,"mods":["command"]},{"id":"yt","type":"launch","label":"YouTube","target":"https://www.youtube.com/"},{"id":"saf","type":"launch","label":"Safari","target":"/Applications/Safari.app"},{"id":"sig","type":"text","label":"Sig","text":"regards"}]}]}"#
    check("a valid deck is accepted", (saveDeck(goodDeck)?["t"] as? String) == "deck.saved")

    // deck.get returns what the Mac stored.
    client.sendJSON(["v": 1, "t": "deck.get"])
    let returned = client.waitFor(type: "deck")
    check("deck.get returns the stored deck", returned?["deck"] != nil)
}

group("WebSocket — shortcut.run resolves ids, never targets")
do {
    guard let client = authedClient else { check("have an authed client", false); exit(1) }

    _ = takeCaptured(); _ = takeOpened()
    client.sendJSON(["v": 1, "t": "shortcut.run", "id": "copy"])
    Thread.sleep(forTimeInterval: 0.25)
    check("a shortcut item fires a key press", takeCaptured() == ["key"])

    client.sendJSON(["v": 1, "t": "shortcut.run", "id": "sig"])
    Thread.sleep(forTimeInterval: 0.25)
    check("a text item types text", takeCaptured() == ["text"])

    client.sendJSON(["v": 1, "t": "shortcut.run", "id": "yt"])
    Thread.sleep(forTimeInterval: 0.3)
    check("an https item opens the URL", takeOpened().urls == ["https://www.youtube.com/"])

    client.sendJSON(["v": 1, "t": "shortcut.run", "id": "saf"])
    Thread.sleep(forTimeInterval: 0.3)
    check("an app item opens the application", takeOpened().apps == ["/Applications/Safari.app"])

    // The decisive property: an id that isn't in the Mac's deck does nothing.
    _ = takeCaptured(); _ = takeOpened()
    client.sendJSON(["v": 1, "t": "shortcut.run", "id": "nosuchbutton"])
    let error = client.waitFor(type: "error")
    Thread.sleep(forTimeInterval: 0.2)
    let opened = takeOpened()
    check("an unknown id is refused and opens nothing",
          error != nil && opened.urls.isEmpty && opened.apps.isEmpty)
}

group("WebSocket — single-controller lease")
do {
    guard let second = WSClient(origin: ORIGIN), second.accepted else {
        check("second handshake", false); exit(1)
    }
    _ = second.waitFor(type: "auth.required")
    second.sendJSON(["v": 1, "t": "auth", "token": token])
    check("a second controller is told the Mac is busy", second.waitFor(type: "busy") != nil)
    second.close()

    // The first controller must still work after the second is turned away.
    _ = takeCaptured()
    authedClient?.sendJSON(["v": 1, "t": "pointer.move", "dx": 1, "dy": 1])
    Thread.sleep(forTimeInterval: 0.25)
    check("the original controller still has the lease", takeCaptured() == ["move"])
}

group("WebSocket — hostile input, and the server survives it")
do {
    // THE regression test. Upstream read the 64-bit payload length into a signed
    // Int, so a high bit made it negative; the bounds check passed and forming
    // the payload range trapped. 14 bytes killed the process.
    let crasher: [UInt8] = [0x81, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0x01, 0, 0, 0, 0]
    if let client = WSClient(origin: ORIGIN), client.accepted {
        client.sendRaw(crasher)
        Thread.sleep(forTimeInterval: 0.4)
        client.close()
    }
    check("negative 64-bit frame length does not crash the server", serverIsAlive())

    // A few more malformed shapes, each followed by a liveness check.
    let hostile: [(String, [UInt8])] = [
        ("reserved opcode 0xF", [0x8F, 0x80, 0, 0, 0, 0]),
        ("length claims 2^63", [0x81, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]),
        ("unmasked client frame", [0x81, 0x05] + Array("hello".utf8)),
        ("truncated header", [0x81]),
        ("continuation with no start", [0x80, 0x80, 0, 0, 0, 0]),
    ]
    for (label, bytes) in hostile {
        if let client = WSClient(origin: ORIGIN), client.accepted {
            client.sendRaw(bytes)
            Thread.sleep(forTimeInterval: 0.25)
            client.close()
        }
        check("survives: \(label)", serverIsAlive())
    }

    // Oversize message: the connection should be dropped, the process should not.
    if let client = WSClient(origin: ORIGIN), client.accepted {
        client.sendFrame(opcode: 0x1, payload: [UInt8](repeating: 0x61, count: 200_000))
        Thread.sleep(forTimeInterval: 0.4)
        client.close()
    }
    check("survives a 200 KB message", serverIsAlive())

    // Slowloris-ish: open sockets and never complete a request.
    var idle: [Int32] = []
    for _ in 0..<12 {
        if let fd = tcpConnect(port: HTTP_PORT) { send(fd, "GET / HTTP/1.1\r\n"); idle.append(fd) }
    }
    check("still serving while 12 requests hang open", serverIsAlive())
    for fd in idle { close(fd) }
}

group("WebSocket — rate limiting")
do {
    guard let client = authedClient else { check("have an authed client", false); exit(1) }
    _ = takeCaptured()
    for _ in 0..<600 {
        client.sendJSON(["v": 1, "t": "pointer.move", "dx": 1, "dy": 1])
    }
    Thread.sleep(forTimeInterval: 0.6)
    let dispatched = takeCaptured().count
    check("a 600-command burst is capped", dispatched < 600, "dispatched \(dispatched)")
    check("but legitimate traffic still got through", dispatched > 50, "dispatched \(dispatched)")
    check("server alive after the burst", serverIsAlive())
}

group("Pause and revoke")
do {
    control.setPaused(true)
    Thread.sleep(forTimeInterval: 0.3)
    _ = takeCaptured()
    authedClient?.sendJSON(["v": 1, "t": "pointer.move", "dx": 5, "dy": 5])
    Thread.sleep(forTimeInterval: 0.3)
    check("input is dropped while paused", takeCaptured().isEmpty)

    control.setPaused(false)
    Thread.sleep(forTimeInterval: 0.3)
    authedClient?.sendJSON(["v": 1, "t": "pointer.move", "dx": 5, "dy": 5])
    Thread.sleep(forTimeInterval: 0.3)
    check("input resumes after unpausing", takeCaptured() == ["move"])

    authedClient?.close()

    // Revocation must invalidate the token for future connections.
    sessions.revokeAll()
    Thread.sleep(forTimeInterval: 0.2)
    if let client = WSClient(origin: ORIGIN), client.accepted {
        _ = client.waitFor(type: "auth.required")
        client.sendJSON(["v": 1, "t": "auth", "token": token])
        check("a revoked token is refused", client.waitFor(type: "auth.failed") != nil)
        client.close()
    } else {
        check("a revoked token is refused", false)
    }
}

// MARK: - The app picker's response

// The payload is a few hundred kilobytes — one JSON object per installed app,
// each carrying a base64 PNG icon. That is far larger than any other message
// this protocol sends, and far past `Limits.maxCommandBytes`, so it is worth
// proving it actually arrives intact rather than assuming it does.
group("App picker response")
do {
    setAppListPayload(AppList.json())
    defer { setAppListPayload("[]") }

    // The revoke test above invalidated every token, so pair again rather than
    // depending on the order these groups happen to run in.
    sessions.regeneratePIN()
    var freshToken = ""
    if let response = httpRequest("POST", "/pair", origin: ORIGIN, body: "pin=\(sessions.pin)"),
       let data = response.body.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let issued = object["token"] as? String {
        freshToken = issued
    }
    check("paired for the app picker test", !freshToken.isEmpty)

    guard let client = WSClient(origin: ORIGIN), client.accepted else {
        check("handshake for the app picker test", false); exit(1)
    }
    _ = client.waitFor(type: "auth.required")
    client.sendJSON(["v": 1, "t": "auth", "token": freshToken])
    guard client.waitFor(type: "welcome") != nil else {
        check("authenticated for the app picker test", false); exit(1)
    }

    client.sendJSON(["v": 1, "t": "apps.get"])
    let reply = client.waitFor(type: "apps", attempts: 10)
    check("a large apps response arrives whole", reply != nil)

    let apps = reply?["apps"] as? [[String: String]]
    check("it decodes as an array of app objects", apps != nil)
    check("it is not empty", (apps?.count ?? 0) > 10)

    let icons = (apps ?? []).compactMap { $0["icon"] }.filter { !$0.isEmpty }
    check("icons are included", !icons.isEmpty)

    // Every icon the picker offers must pass the validator, or selecting that
    // app would produce a deck the Mac then refuses to save.
    let oversized = icons.filter { $0.utf8.count > DeckValidator.maxIconDataURIBytes }
    check("no icon exceeds the deck validator's cap", oversized.isEmpty,
          "\(oversized.count) of \(icons.count) over \(DeckValidator.maxIconDataURIBytes) bytes")

    // The round trip that actually matters: pick an app, save it, run it.
    if let app = (apps ?? []).first(where: { $0["path"] == "/Applications/Safari.app" })
        ?? (apps ?? []).first {
        let item = "{\"id\":\"a1\",\"type\":\"launch\",\"label\":\"Picked\","
            + "\"target\":\"/Applications/Safari.app\",\"icon\":\"\(app["icon"] ?? "")\"}"
        let deck = "{\"folders\":[{\"id\":\"f1\",\"name\":\"F\",\"items\":[\(item)]}]}"
        client.sendJSON(["v": 1, "t": "deck.save", "deck": deck])
        check("a deck built from a picked app is accepted",
              client.waitFor(type: "deck.saved") != nil)

        _ = takeOpened()
        client.sendJSON(["v": 1, "t": "shortcut.run", "id": "a1"])
        Thread.sleep(forTimeInterval: 0.3)
        check("and the picked app launches", takeOpened().apps == ["/Applications/Safari.app"])
    } else {
        check("a deck built from a picked app is accepted", false)
        check("and the picked app launches", false)
    }

    client.close()
}

// MARK: - Summary

http.stop()
control.stop()

print("\n" + String(repeating: "─", count: 50))
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
