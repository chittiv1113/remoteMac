import AppKit
import CoreGraphics
import Foundation

/// Synthesizes real mouse and keyboard input with CGEvent (Quartz Event Services).
///
/// ⚠️ Requires the **Accessibility** permission (System Settings › Privacy &
///    Security › Accessibility). Without it, events are silently dropped.
///
/// Two serial queues, deliberately:
///   - `pointerQueue` owns the drag state and the 120 Hz interpolation timer.
///   - `keyQueue` owns keystrokes, text and launches.
///
/// They are separate because a modified keystroke sleeps ~32 ms while the
/// modifier settles, and on a shared queue that stalls cursor interpolation
/// visibly. Ordering is still guaranteed *within* each stream, and nothing
/// needs ordering *across* them: click commands carry their own modifier flags
/// rather than depending on a modifier key being held by the other queue.
enum EventInjector {

    private static let pointerQueue = DispatchQueue(label: "com.remotemac.pointer")
    private static let keyQueue = DispatchQueue(label: "com.remotemac.key")

    // Drag state — touched only on pointerQueue.
    private static var isMouseDown = false
    private static var downButton: CGMouseButton = .left

    // MARK: - Entry point

    static func perform(_ command: Command) {
        switch command {
        case .pointerMove(let dx, let dy):
            pointerQueue.async { move(dx: dx, dy: dy) }
        case .pointerScroll(let dx, let dy):
            pointerQueue.async { scroll(dx: dx, dy: dy) }
        case .pointerDown(let button, let mods):
            pointerQueue.async { mouseDown(right: button == .right, mods: mods) }
        case .pointerUp:
            pointerQueue.async { mouseUp() }
        case .pointerClick(let button, let count, let mods):
            pointerQueue.async { click(right: button == .right, count: count, mods: mods) }
        case .textInsert(let text):
            keyQueue.async { typeText(text) }
        case .keyPress(let keyCode, let mods):
            keyQueue.async { keyPress(keyCode: keyCode, mods: mods) }
        case .swipe(let dir, let fingers):
            keyQueue.async { swipe(dir, fingers: fingers) }
        case .systemAction(let action):
            keyQueue.async { run(action) }
        case .shortcutRun, .deckGet, .deckSave, .appsGet, .ping:
            break   // answered by CommandRouter; not an input event
        }
    }

    /// Release anything being held. Called on disconnect, pause and quit so a
    /// dropped connection mid-drag cannot leave a button down.
    static func releaseAll() {
        pointerQueue.async {
            if isMouseDown {
                let pos = currentLocation()
                let upType: CGEventType = downButton == .right ? .rightMouseUp : .leftMouseUp
                postMouse(upType, at: pos, button: downButton, clickState: 1, flags: [])
                isMouseDown = false
            }
            stopMoveLoop()
            hasCursor = false   // resync to the physical cursor next session
        }
    }

    // MARK: - Smooth motion (sub-pixel virtual cursor + adaptive interpolation)
    //
    // Received deltas are accumulated into a sub-pixel virtual target rather than
    // applied as jumps; a 120 Hz timer walks the real cursor toward that target at
    // a rate matched to the *measured* packet interval. This absorbs transmission
    // discretisation and arrival jitter. On a fast link the cursor reaches the
    // target within a frame, so added latency is ~0.
    //
    private static var renderPos = CGPoint.zero
    private static var targetPos = CGPoint.zero
    private static var hasCursor = false
    private static var lastPacketTime: CFTimeInterval = 0
    private static var interArrival: Double = 1.0 / 90.0
    private static var moveTimer: DispatchSourceTimer?
    private static var idleFrames = 0
    private static let stepHz: Double = 120
    private static let followGain: Double = 1.5
    private static let idleEps: Double = 0.04
    private static let resyncDist: Double = 8.0

    /// How often the physical cursor position is re-read, to notice a real mouse
    /// being moved underneath us. Reading it is a synchronous WindowServer round
    /// trip, so it is sampled rather than done per packet at 60–120 Hz.
    private static let resyncInterval: CFTimeInterval = 0.1
    private static var lastResyncCheck: CFTimeInterval = 0

    private static func move(dx: Double, dy: Double) {
        let t = CFAbsoluteTimeGetCurrent()

        if !hasCursor || t - lastResyncCheck > resyncInterval {
            lastResyncCheck = t
            let real = currentLocation()
            if !hasCursor || hypot(real.x - renderPos.x, real.y - renderPos.y) > resyncDist {
                renderPos = real; targetPos = real; hasCursor = true
            }
        }

        if lastPacketTime > 0 {
            let d = t - lastPacketTime
            if d > 0.002 && d < 0.2 { interArrival = interArrival * 0.8 + d * 0.2 }
        }
        lastPacketTime = t
        targetPos = clampToDisplays(CGPoint(x: targetPos.x + dx, y: targetPos.y + dy))
        idleFrames = 0
        startMoveLoop()
    }

    private static func startMoveLoop() {
        guard moveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pointerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / stepHz, leeway: .milliseconds(1))
        timer.setEventHandler { stepMove() }
        moveTimer = timer
        timer.resume()
    }

    private static func stopMoveLoop() {
        moveTimer?.cancel(); moveTimer = nil; idleFrames = 0
    }

    private static func stepMove() {
        let remX = targetPos.x - renderPos.x
        let remY = targetPos.y - renderPos.y
        if hypot(remX, remY) < idleEps {
            idleFrames += 1
            if idleFrames > 8 { stopMoveLoop() }   // zero idle CPU once settled
            return
        }
        idleFrames = 0
        let interval = 1.0 / stepHz
        let frac = min(1.0, interval * followGain / max(interArrival, interval))
        renderPos.x += remX * frac
        renderPos.y += remY * frac
        postAtRenderPos()
    }

    private static func postAtRenderPos() {
        let p = CGPoint(x: renderPos.x.rounded(), y: renderPos.y.rounded())
        if isMouseDown {
            let dragType: CGEventType = downButton == .right ? .rightMouseDragged : .leftMouseDragged
            postMouse(dragType, at: p, button: downButton, clickState: 1, flags: heldFlags)
        } else {
            postMouse(.mouseMoved, at: p, button: .left, clickState: 1, flags: [])
        }
    }

    private static func syncCursorBase(_ p: CGPoint) {
        renderPos = p; targetPos = p; hasCursor = true
    }

    // MARK: - Mouse

    private static func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Modifier flags to apply to drag events while a button is held, so a
    /// Shift-drag stays a Shift-drag for its whole duration.
    private static var heldFlags: CGEventFlags = []

    private static func mouseDown(right: Bool, mods: [Modifier]) {
        let pos = currentLocation()
        downButton = right ? .right : .left
        isMouseDown = true
        heldFlags = flags(for: mods)
        let downType: CGEventType = right ? .rightMouseDown : .leftMouseDown
        postMouse(downType, at: pos, button: downButton, clickState: 1, flags: heldFlags)
        syncCursorBase(pos)
    }

    private static func mouseUp() {
        let pos = currentLocation()
        let upType: CGEventType = downButton == .right ? .rightMouseUp : .leftMouseUp
        postMouse(upType, at: pos, button: downButton, clickState: 1, flags: heldFlags)
        isMouseDown = false
        heldFlags = []
        syncCursorBase(pos)
    }

    private static func click(right: Bool, count: Int, mods: [Modifier]) {
        let pos = currentLocation()
        let state = max(1, count)
        let f = flags(for: mods)
        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right)
                  : (.leftMouseDown, .leftMouseUp, .left)
        postMouse(downType, at: pos, button: button, clickState: state, flags: f)
        postMouse(upType, at: pos, button: button, clickState: state, flags: f)
    }

    private static func flags(for mods: [Modifier]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in mods { f.insert(m.flag) }
        return f
    }

    /// Flags are passed in explicitly, never inherited.
    ///
    /// Clearing them unconditionally would be simpler but makes Cmd-click and
    /// Shift-click impossible — no range-select, no multi-select, no
    /// open-link-in-new-tab. Setting them from the command gives both: a stale
    /// Control flag can never turn a left click into a right click, and real
    /// modifier clicks still work.
    private static func postMouse(_ type: CGEventType, at point: CGPoint,
                                  button: CGMouseButton, clickState: Int, flags: CGEventFlags) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = flags
        if clickState > 1 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.post(tap: .cghidEventTap)
    }

    private static func scroll(dx: Double, dy: Double) {
        // Negated for natural scrolling, the macOS default. Someone who turns
        // natural scrolling off flips it back in the client's settings, so there
        // is only one place that can invert it.
        let vertical = Int32((-dy).rounded())
        let horizontal = Int32((-dx).rounded())
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: vertical, wheel2: horizontal, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    /// Posts **real modifier key down/up events** around the main key, not just
    /// flags. Flags alone do not trigger WindowServer hotkeys, and leaving the
    /// modifier state set causes later clicks to be misread.
    private static func keyPress(keyCode: CGKeyCode, mods: [Modifier]) {
        let source = CGEventSource(stateID: .combinedSessionState)
        var flags: CGEventFlags = []

        for modifier in mods {
            flags.insert(modifier.flag)
            postKey(source: source, key: modifier.keyCode, down: true, flags: flags)
        }
        // Symbolic hotkeys (Mission Control, Spaces) are timing sensitive; give
        // WindowServer a moment to observe the modifier as held.
        if !mods.isEmpty { usleep(15000) }
        postKey(source: source, key: keyCode, down: true, flags: flags)
        usleep(12000)
        postKey(source: source, key: keyCode, down: false, flags: flags)
        usleep(5000)
        for modifier in mods.reversed() {
            flags.remove(modifier.flag)
            postKey(source: source, key: modifier.keyCode, down: false, flags: flags)
        }
    }

    private static func postKey(source: CGEventSource?, key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Insert arbitrary Unicode text, chunked by grapheme cluster.
    ///
    /// Two details that are easy to get wrong:
    ///
    ///  - **Chunked, never splitting a grapheme.** Apple documents the unicode
    ///    string override as advisory, and some text systems truncate a long
    ///    one. Chunks are capped at 16 UTF-16 units and always end on a cluster
    ///    boundary, so an emoji or a combining sequence is never cut in half.
    ///
    ///  - **Payload on keyDown only.** Text insertion happens on keyDown; an
    ///    app that also reads the up event would receive the text twice.
    private static let maxChunkUTF16 = 16

    private static func typeText(_ string: String) {
        guard !string.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        for chunk in graphemeChunks(string, maxUTF16: maxChunkUTF16) {
            var units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)

            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Split into chunks of at most `maxUTF16` UTF-16 units without ever breaking
    /// a grapheme cluster. A single cluster longer than the cap (a long ZWJ emoji
    /// sequence, say) is emitted whole rather than mangled.
    static func graphemeChunks(_ string: String, maxUTF16: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentCount = 0
        for cluster in string {
            let clusterCount = String(cluster).utf16.count
            if currentCount > 0, currentCount + clusterCount > maxUTF16 {
                chunks.append(current)
                current = ""
                currentCount = 0
            }
            current.append(cluster)
            currentCount += clusterCount
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Gestures and system actions

    private static func swipe(_ dir: SwipeDirection, fingers: Int) {
        switch (fingers, dir) {
        case (3, .up):    run(.missionControl)
        case (3, .down):  run(.appExpose)
        case (3, .left):  keyPress(keyCode: 123, mods: [.command])   // ⌘← back
        case (3, .right): keyPress(keyCode: 124, mods: [.command])   // ⌘→ forward
        // Not reachable in practice: see the note on SystemAction.
        case (4, .left):  run(.previousSpace)
        case (4, .right): run(.nextSpace)
        case (4, .up):    run(.missionControl)
        default: break
        }
    }

    private static func run(_ action: SystemAction) {
        switch action {
        case .missionControl:
            // Synthetic Ctrl+Up is unreliable for Mission Control; launching the
            // app is the documented, stable route.
            openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case .appExpose:
            keyPress(keyCode: 125, mods: [.control])                 // ⌃↓
        case .previousSpace:
            keyPress(keyCode: 123, mods: [.control])                 // ⌃←
        case .nextSpace:
            keyPress(keyCode: 124, mods: [.control])                 // ⌃→
        case .zoomIn:
            keyPress(keyCode: 24, mods: [.command])                  // ⌘=
        case .zoomOut:
            keyPress(keyCode: 27, mods: [.command])                  // ⌘-
        }
    }

    // MARK: - Launching (allowlisted targets only)

    /// Open an https URL in the user's default browser.
    ///
    /// Note what is *absent*: no `Process`, no `/usr/bin/open`, and no path from
    /// a phone-supplied string to a shell. Callers must have already passed the
    /// target through `DeckValidator.isPermittedTarget`.
    static func open(url: URL) {
        keyQueue.async { NSWorkspace.shared.open(url) }
    }

    static func openApplication(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                NSLog("[EventInjector] could not open application: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Displays

    /// Union of all active displays, cached.
    ///
    /// `clampToDisplays` runs on every pointer packet *and* every interpolation
    /// frame, and enumerating displays is a WindowServer round trip. Caching it
    /// and invalidating from a reconfiguration callback keeps that off the hot
    /// path without going stale when a display is plugged in.
    private static var cachedBounds: CGRect?
    private static let boundsLock = NSLock()

    static func startWatchingDisplays() {
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            EventInjector.invalidateDisplayBounds()
        }, nil)
    }

    static func invalidateDisplayBounds() {
        boundsLock.lock(); cachedBounds = nil; boundsLock.unlock()
    }

    private static func clampToDisplays(_ point: CGPoint) -> CGPoint {
        let bounds = desktopBounds()
        let x = min(max(point.x, bounds.minX), bounds.maxX - 1)
        let y = min(max(point.y, bounds.minY), bounds.maxY - 1)
        return CGPoint(x: x, y: y)
    }

    private static func desktopBounds() -> CGRect {
        boundsLock.lock()
        if let cached = cachedBounds { boundsLock.unlock(); return cached }
        boundsLock.unlock()

        var computed = CGDisplayBounds(CGMainDisplayID())
        var count: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetActiveDisplayList(count, &displays, &count) == .success {
                var rect = CGRect.null
                for display in displays { rect = rect.union(CGDisplayBounds(display)) }
                if !rect.isNull { computed = rect }
            }
        }

        boundsLock.lock(); cachedBounds = computed; boundsLock.unlock()
        return computed
    }
}
