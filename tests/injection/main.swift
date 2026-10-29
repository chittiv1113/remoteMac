import AppKit
import CoreGraphics
import Darwin
import Foundation

// End-to-end injection check against the *running* helper.
//
// This is a client, not a server: it pairs over HTTP, opens the control socket,
// and sends ordinary v1 commands. The helper — which holds the Accessibility
// grant — does the actual CGEvent injection. That is the whole point: it
// verifies the real chain, phone protocol → validation → CGEvent → WindowServer,
// rather than stubbing the last step like the other suites deliberately do.
//
// Usage: injection <pin> [--with-keyboard]
//
// Pointer checks are always safe: the cursor is moved and then put back exactly
// where it was. Keyboard checks are opt-in because they type into a real
// application; they open a fresh TextEdit document, type there, read the result
// back through the clipboard, then clear it.

let HTTP_PORT: UInt16 = 8765
let WS_PORT: UInt16 = 8766
let ORIGIN = "http://127.0.0.1:8765"

var passed = 0, failed = 0, skipped = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✓ \(label)") }
    else { failed += 1; print("  ✗ \(label)\(detail.isEmpty ? "" : " — " + detail)") }
}
func group(_ name: String) { print("\n\(name)") }
func note(_ text: String) { print("    \(text)") }

// MARK: - Sockets

func tcpConnect(_ port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard ok == 0 else { close(fd); return nil }
    var tv = timeval(tv_sec: 4, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var sent = 0
    bytes.withUnsafeBufferPointer { buf in
        while sent < bytes.count {
            let n = write(fd, buf.baseAddress! + sent, bytes.count - sent)
            if n <= 0 { break }
            sent += n
        }
    }
}

func readSome(_ fd: Int32) -> [UInt8] {
    var chunk = [UInt8](repeating: 0, count: 8192)
    let n = read(fd, &chunk, chunk.count)
    return n > 0 ? Array(chunk[0..<n]) : []
}

// MARK: - Pairing

func pair(pin: String) -> String? {
    guard let fd = tcpConnect(HTTP_PORT) else { return nil }
    defer { close(fd) }
    let body = "pin=\(pin)"
    let request = "POST /pair HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: \(ORIGIN)\r\n"
        + "Content-Type: application/x-www-form-urlencoded\r\n"
        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    writeAll(fd, Array(request.utf8))

    var raw = [UInt8]()
    while true { let more = readSome(fd); if more.isEmpty { break }; raw += more }
    let text = String(decoding: raw, as: UTF8.self)
    guard let marker = text.range(of: "\r\n\r\n") else { return nil }
    let payload = String(text[marker.upperBound...])
    guard let data = payload.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let error = object["error"] as? String { note("pair failed: \(error)"); return nil }
    return object["token"] as? String
}

// MARK: - Control socket

final class Control {
    let fd: Int32
    private var buffer = [UInt8]()
    private(set) var connected = false

    init?() {
        guard let fd = tcpConnect(WS_PORT) else { return nil }
        self.fd = fd
        let handshake = "GET / HTTP/1.1\r\nHost: 127.0.0.1:8766\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nOrigin: \(ORIGIN)\r\n\r\n"
        writeAll(fd, Array(handshake.utf8))
        let first = readSome(fd)
        let text = String(decoding: first, as: UTF8.self)
        connected = text.contains("101")
        if let marker = text.range(of: "\r\n\r\n") {
            let consumed = text[..<marker.upperBound].utf8.count
            if first.count > consumed { buffer += Array(first[consumed...]) }
        }
    }

    func send(_ object: [String: Any]) {
        var payload = object
        payload["v"] = 1
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let bytes = Array(data)
        var frame: [UInt8] = [0x81]
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        if bytes.count < 126 { frame.append(0x80 | UInt8(bytes.count)) }
        else {
            frame.append(0x80 | 126)
            frame.append(UInt8((bytes.count >> 8) & 0xff)); frame.append(UInt8(bytes.count & 0xff))
        }
        frame += mask
        for (i, b) in bytes.enumerated() { frame.append(b ^ mask[i % 4]) }
        writeAll(fd, frame)
    }

    func waitFor(_ type: String, attempts: Int = 8) -> [String: Any]? {
        for _ in 0..<attempts {
            guard let text = nextText() else { return nil }
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if object["t"] as? String == type { return object }
            if object["t"] as? String == "error" { note("server error: \(object["reason"] ?? "?")") }
        }
        return nil
    }

    private func nextText() -> String? {
        for _ in 0..<40 {
            if let frame = pop() {
                if frame.0 == 0x8 { return nil }
                if frame.0 == 0x1 { return String(decoding: frame.1, as: UTF8.self) }
                continue
            }
            let more = readSome(fd)
            if more.isEmpty { return nil }
            buffer += more
        }
        return nil
    }

    private func pop() -> (UInt8, [UInt8])? {
        guard buffer.count >= 2 else { return nil }
        let opcode = buffer[0] & 0x0F
        var length = Int(buffer[1] & 0x7F)
        var index = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = (Int(buffer[2]) << 8) | Int(buffer[3]); index = 4
        }
        guard buffer.count >= index + length else { return nil }
        let payload = Array(buffer[index ..< index + length])
        buffer.removeFirst(index + length)
        return (opcode, payload)
    }

    func close() { Darwin.close(fd) }
}

// MARK: - Helpers

/// Reading the cursor position needs no special permission.
func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func sleepMS(_ ms: Int) { usleep(useconds_t(ms * 1000)) }

func frontmostApp() -> String {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<none>"
}

// MARK: - Run

let args = CommandLine.arguments
let withKeyboard = args.contains("--with-keyboard")
let pin = args.count >= 2 && !args[1].hasPrefix("--") ? args[1] : nil

/// Cache the session token so a PIN is only ever needed once. The helper keeps
/// its half in session.json, so the pairing survives restarts on both sides.
let tokenCache = URL(fileURLWithPath: "/tmp/remotemac-test-token")
func cachedToken() -> String? {
    guard let text = try? String(contentsOf: tokenCache, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count == 64 ? trimmed : nil
}

print("remoteMac — real injection check")
print("Driving the running helper over its real protocol; the helper does the injecting.")

group("Pairing with the live helper")
var token: String
if let existing = cachedToken() {
    token = existing
    check("reusing the cached pairing (no PIN needed)", true)
} else if let pin {
    guard let fresh = pair(pin: pin) else {
        check("paired", false, "check the PIN in the menu bar, and that the helper is running")
        exit(1)
    }
    token = fresh
    try? fresh.write(to: tokenCache, atomically: true, encoding: .utf8)
    check("paired with the PIN", true)
    check("token is 256 bits", token.count == 64)
} else {
    check("paired", false, "no cached token — pass the PIN from the menu bar")
    exit(1)
}

guard let control = Control(), control.connected else {
    check("control socket connected", false)
    exit(1)
}
check("control socket connected", true)
_ = control.waitFor("auth.required")
control.send(["t": "auth", "token": token])
if control.waitFor("welcome") == nil {
    // The cached token may have been revoked, or the state file reset.
    try? FileManager.default.removeItem(at: tokenCache)
    check("authenticated", false,
          "cached pairing was rejected — it has been cleared, re-run with the PIN")
    exit(1)
}
check("authenticated", true)

// MARK: Pointer

group("Pointer — does the cursor actually move?")
let origin = cursor()
note("cursor starts at (\(Int(origin.x)), \(Int(origin.y)))")

// Park somewhere predictable first, away from screen edges where clamping bites.
let screen = CGDisplayBounds(CGMainDisplayID())
let parkX = screen.midX, parkY = screen.midY
var moved = cursor()
// Walk to the middle with bounded deltas, as a real client would.
for _ in 0..<60 {
    let dx = max(-150, min(150, parkX - moved.x))
    let dy = max(-150, min(150, parkY - moved.y))
    if abs(dx) < 1 && abs(dy) < 1 { break }
    control.send(["t": "pointer.move", "dx": dx, "dy": dy])
    sleepMS(30)
    moved = cursor()
}
let parked = cursor()
let reachedCentre = hypot(parked.x - parkX, parked.y - parkY) < 40
check("cursor can be driven to a target position", reachedCentre,
      "ended at (\(Int(parked.x)), \(Int(parked.y))), wanted (\(Int(parkX)), \(Int(parkY)))")

if !reachedCentre {
    note("If this failed, the helper most likely lacks Accessibility permission —")
    note("commands are arriving (the server accepted them) but events are dropped.")
}

// A precise relative move.
let before = cursor()
control.send(["t": "pointer.move", "dx": 120, "dy": 80])
sleepMS(900)          // let the 120 Hz interpolation fully settle
let after = cursor()
let dx = after.x - before.x, dy = after.y - before.y
check("a +120,+80 move lands within a few pixels",
      abs(dx - 120) < 12 && abs(dy - 80) < 12,
      "observed (\(Int(dx)), \(Int(dy)))")

// Interpolation should produce a smooth path, not a teleport, but still settle.
let beforeSmooth = cursor()
control.send(["t": "pointer.move", "dx": -100, "dy": 0])
sleepMS(40)
let midway = cursor()
sleepMS(400)
let settled = cursor()
check("motion is interpolated rather than teleported",
      abs(midway.x - beforeSmooth.x) < 100 && abs(settled.x - beforeSmooth.x + 100) < 12,
      "mid \(Int(midway.x - beforeSmooth.x)), final \(Int(settled.x - beforeSmooth.x))")

// Bounds: a huge delta is rejected by validation, so the cursor must not jump.
let beforeReject = cursor()
control.send(["t": "pointer.move", "dx": 99999, "dy": 99999])
sleepMS(900)
check("an out-of-range delta is refused and the cursor stays put",
      hypot(cursor().x - beforeReject.x, cursor().y - beforeReject.y) < 5)

// Put the cursor back where the user left it.
var restore = cursor()
for _ in 0..<60 {
    let rx = max(-150, min(150, origin.x - restore.x))
    let ry = max(-150, min(150, origin.y - restore.y))
    if abs(rx) < 1 && abs(ry) < 1 { break }
    control.send(["t": "pointer.move", "dx": rx, "dy": ry])
    sleepMS(30)
    restore = cursor()
}
sleepMS(300)
check("cursor restored to where it started",
      hypot(cursor().x - origin.x, cursor().y - origin.y) < 40,
      "now at (\(Int(cursor().x)), \(Int(cursor().y)))")

// MARK: Keyboard

if withKeyboard {
    group("Keyboard — does text reach a real application?")

    let pasteboard = NSPasteboard.general
    let savedClipboard = pasteboard.string(forType: .string)
    note("clipboard saved; it will be restored at the end")

    // A fresh, empty TextEdit document is a safe, known target.
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    let opened = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: textEdit, configuration: config) { _, _ in opened.signal() }
    _ = opened.wait(timeout: .now() + 10)
    sleepMS(2500)

    /// Guard every single keystroke batch, not just the first.
    ///
    /// The original version checked focus once and then sent a dozen keystrokes
    /// over several seconds. Focus moved in between and the keys landed in a
    /// browser. A one-time check is necessary but nowhere near sufficient: the
    /// window that owns the keyboard can change at any moment, so the check has
    /// to sit immediately before each send.
    var aborted = false
    func guarded(_ what: String, _ action: () -> Void) {
        guard !aborted else { return }
        let front = frontmostApp()
        guard front == "com.apple.TextEdit" else {
            aborted = true
            failed += 1
            print("  ✗ ABORTED before \(what) — frontmost became \(front)")
            note("No further keys were sent. Nothing was typed into that app.")
            return
        }
        action()
    }

    let front = frontmostApp()
    let isTextEdit = front == "com.apple.TextEdit"
    check("TextEdit is frontmost before typing", isTextEdit, "frontmost is \(front)")

    if isTextEdit {
        // New blank document: ⌘N.
        guarded("⌘N") { control.send(["t": "key.press", "keyCode": 45, "mods": ["command"]]) }
        sleepMS(1200)

        let sample = "7 remoteMac ok 👋"
        guarded("typing") { control.send(["t": "text.insert", "text": sample]) }
        sleepMS(900)

        /// Read the document back through the clipboard.
        ///
        /// A trailing marker is typed first. TextEdit keeps the last word in an
        /// uncommitted auto-capitalisation state until a word boundary arrives,
        /// and uncommitted text does not copy — reading without this returns an
        /// empty string even though the text is plainly on screen. The marker
        /// forces the commit and is then stripped.
        func documentText() -> String {
            guarded("commit marker") { control.send(["t": "text.insert", "text": "|"]) }
            sleepMS(700)
            pasteboard.clearContents()
            guarded("⌘A") { control.send(["t": "key.press", "keyCode": 0, "mods": ["command"]]) }
            sleepMS(400)
            guarded("⌘C") { control.send(["t": "key.press", "keyCode": 8, "mods": ["command"]]) }
            var captured = ""
            for _ in 0..<10 {
                sleepMS(250)
                if let text = pasteboard.string(forType: .string), !text.isEmpty {
                    captured = text
                    break
                }
            }
            // Take the marker back out so reading leaves the document exactly as
            // it was found — otherwise a later backspace deletes the marker
            // instead of the character under test.
            guarded("deselect") { control.send(["t": "key.press", "keyCode": 124, "mods": ["command"]]) }
            sleepMS(300)
            guarded("drop marker") { control.send(["t": "key.press", "keyCode": 51, "mods": []]) }
            sleepMS(300)
            return captured.hasSuffix("|") ? String(captured.dropLast()) : captured
        }

        let typed = documentText()
        check("typed text arrives verbatim", typed == sample,
              "got \(typed.debugDescription)")
        check("the emoji survived as one character",
              typed.contains("👋") && typed.count == sample.count,
              "\(typed.count) graphemes, expected \(sample.count)")

        // Delete the emoji with a single backspace — a code-unit diff would
        // have eaten the space before it as well.
        guarded("⌘→") { control.send(["t": "key.press", "keyCode": 124, "mods": ["command"]]) }
        sleepMS(300)
        guarded("⌫") { control.send(["t": "key.press", "keyCode": 51, "mods": []]) }
        sleepMS(500)
        let afterDelete = documentText()
        check("one backspace deletes exactly the emoji",
              afterDelete == "7 remoteMac ok ", "got \(afterDelete.debugDescription)")

        // Clear the scratch document so nothing is left behind.
        guarded("clear ⌘A") { control.send(["t": "key.press", "keyCode": 0, "mods": ["command"]]) }
        sleepMS(300)
        guarded("clear ⌫") { control.send(["t": "key.press", "keyCode": 51, "mods": []]) }
        sleepMS(400)
        if !aborted { note("scratch document cleared — close TextEdit when you like") }
    } else {
        skipped += 1
        note("skipped the typing checks rather than type into an unknown app")
    }

    pasteboard.clearContents()
    if let savedClipboard {
        pasteboard.setString(savedClipboard, forType: .string)
        note("clipboard restored")
    } else {
        // It held nothing we could save, so leave it empty rather than leaving
        // behind whatever ⌘C grabbed during the test.
        note("clipboard was empty beforehand — cleared rather than left with test data")
    }
} else {
    skipped += 1
    print("\nKeyboard checks skipped (pass --with-keyboard to run them).")
}

control.close()

print("\n" + String(repeating: "─", count: 52))
print("\(passed) passed, \(failed) failed\(skipped > 0 ? ", \(skipped) skipped" : "")")
exit(failed == 0 ? 0 : 1)
