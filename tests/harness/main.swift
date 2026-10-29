import Foundation

// A live instance of the real servers on test ports, with the PIN printed to
// stdout so an automated client can pair.
//
// This exists so the browser-level checks (tests/ui-check.js) drive the actual
// StaticHTTPServer, ControlSocket and CommandRouter rather than a mock. Input is
// logged, never injected: `inject` writes a line instead of synthesizing an
// event, so a UI smoke test cannot move the real cursor.
//
// Not shipped in the app bundle — build.sh compiles Sources/ only.

let httpPort: UInt16 = 18765
let controlPort: UInt16 = 18766

let sessions = SessionStore(fileURL: URL(fileURLWithPath: "/tmp/remotemac-harness-session.json"))
let http = StaticHTTPServer(port: httpPort, controlPort: controlPort, sessions: sessions)
let control = ControlSocket(port: controlPort, httpPort: httpPort, sessions: sessions)

let router = CommandRouter(
    deck: DeckStore.load() ?? .empty,
    effects: CommandRouter.Effects(
        inject: { command in
            // Logged, not injected.
            print("COMMAND \(command.label)")
            fflush(stdout)
        },
        openURL: { print("OPEN-URL \($0.absoluteString)"); fflush(stdout) },
        openApplication: { print("OPEN-APP \($0.path)"); fflush(stdout) },
        allowedAppPaths: { AppList.allowedPaths() },
        appListJSON: { AppList.json() }
    )
)

control.onCommand = { command, controller in
    router.handle(command) { controller.send(json: $0) }
}

AppList.warmUp()

do {
    try http.start()
    try control.start()
} catch {
    print("FATAL \(error)")
    exit(1)
}

print("PIN \(sessions.pin)")
print("HTTP http://127.0.0.1:\(httpPort)")
print("READY")
fflush(stdout)

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
RunLoop.main.run()
