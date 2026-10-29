# remoteMac

Your phone as a trackpad, keyboard, and shortcut deck for a Mac across the
room — in mobile Safari. No app to install, no account, no cloud.

Built for one situation: the Mac is plugged into the TV and you are on the
sofa.

```
 Phone browser                          Mac menu-bar app
┌────────────────────────┐            ┌──────────────────────────────┐
│ page served by the Mac │  HTTP      │ static file server           │
│ (html/css/js, no deps) │ ◀────────▶ │                              │
│ touch → gestures       │  WebSocket │ validate → route             │
│ textarea → text diff   │ ◀────────▶ │ CGEvent injection            │
└────────────────────────┘            └──────────────┬───────────────┘
                                         macOS WindowServer → HDMI → TV
```

A finger slides, the phone sends `{"t":"pointer.move","dx":5,"dy":-2}`, the Mac
validates it and synthesizes a `CGEvent`, and the cursor moves on the TV.
Typing is synthetic keypresses into whatever app has focus — which is why
typing into Terminal works, and why there is deliberately **no
command-execution channel** anywhere in the protocol.

> **Read [SECURITY.md](SECURITY.md) before running this.** Anything that can
> reach the Mac's port can type into it. Traffic is encrypted, but the trust
> anchor is a certificate you install by hand — this belongs on a trusted home
> network and must never be port-forwarded.

## What it does

- **Trackpad** — move, tap, double-tap, right-click (two-finger tap), scroll
  with momentum, pinch to zoom, drag, and Cmd- or Shift-click.
- **Keyboard** — types into the focused app, including Terminal. Correct for
  emoji and accents: one backspace deletes one emoji, not half of one.
- **Shortcut deck** — folders of buttons that press a key combination, type
  text, or open an app or an https link. Editable from the phone; every edit is
  validated by the Mac before it is stored.
- **Gestures** — three fingers for Mission Control and app switching.
- **Rotates into place** — portrait is the trackpad, landscape is the keyboard,
  and the keyboard comes up by itself when you click into a text field on the
  Mac.

Deliberately absent: screen streaming, file transfer, a shell endpoint, macros,
analytics, and any third-party script or CDN request.

## Requirements

macOS 13 or later, Xcode **Command Line Tools** (no Xcode, no Homebrew), and a
phone on the same Wi-Fi.

## Install

```bash
./scripts/make-signing-cert.sh   # once — see "Why signing matters" below
./scripts/make-tls-cert.sh       # once — the TLS certificate
./build.sh
open "build/remoteMac.app"
```

Then teach the phone to trust the certificate, once ever:

1. AirDrop `build/tls/remoteMac-CA.cer` to the phone
2. Settings › General › VPN & Device Management › install it
3. Settings › General › About › **Certificate Trust Settings** › turn it on

Step 3 is in a different part of Settings from step 2 and is the one people
miss. Installing alone is not enough — iOS still refuses the connection.

Why bother: the browser will not grant a page the microphone, or several other
capabilities, over a plain HTTP origin. `navigator.mediaDevices` is not merely
blocked there, it is undefined. Encryption is the price of entry for those.

Grant Accessibility when it asks: macOS will not let anything synthesize input
without it. A menu bar icon appears with a QR code and a 6-digit PIN. Scan the
code, enter the PIN once, and the phone is paired.

### Why signing matters

macOS ties the Accessibility permission to the app's code signature. An ad-hoc
signature is derived from the binary's contents, so **every rebuild looks like
a different app and silently voids the grant** — the toggle stays switched on
in System Settings while matching nothing, and injected events are dropped
with no error logged anywhere. `make-signing-cert.sh` creates a self-signed
certificate in your login keychain, which pins the identity so the grant
survives rebuilds. It is free and is not a developer account.

## Build

```bash
./build.sh                                  # compile + sign
CODESIGN_IDENTITY="<cert name>" ./build.sh   # pick an identity explicitly
```

`build.sh` compiles with `swiftc`, assembles the `.app` by hand, generates the
`Info.plist`, and signs. Output is `build/remoteMac.app`. It does not launch
anything: starting the app opens a listening port, which should be a decision
rather than a side effect of building.

## Tests

```bash
./tests/run.sh
```

299 checks in four suites, none of which synthesize real input:

| Suite | What it covers |
|---|---|
| `tests/unit` | Command validation and every rejection path, pairing and token handling, deck validation, key codes, grapheme chunking |
| `tests/integration` | The real listeners over real TCP, driven by a hand-written client: forged `Origin`, bad `Host`, unauthenticated frames, malformed and oversized frames, rate limits, the single-controller lease |
| `tests/logic.test.js` | The pure client logic — text diffing, gesture classification, reconnect pacing, the view state machine, key tables |
| `tests/ui-check.js` | The real UI in a headless browser at an iPhone viewport: pairs, connects, drives all three views, and builds a button in the editor |

A fifth suite is opt-in because it moves your actual cursor and types into a
real application:

```bash
swiftc -sdk "$(xcrun --show-sdk-path)" -framework AppKit \
  tests/injection/main.swift -o /tmp/injection
/tmp/injection <pin> --with-keyboard
```

## Running it at login

See [SERVER.md](SERVER.md).

## Known limits

- **Raising the iOS keyboard sometimes needs one tap.** WebKit only honours
  `focus()` shortly after a real touch. The keyboard *view* always switches;
  the software keyboard usually follows.
- **Switching desktops (Spaces) is not possible.** macOS ignores a synthesized
  ⌃← / ⌃→, so there are no Desktop buttons. The event is delivered correctly —
  it is observable on the session event tap with the Control flag set — but
  WindowServer does not act on it, and the private SkyLight call needs SIP
  disabled. Mission Control still works, and gets you there in one more tap.
- **Nothing works while the Mac is asleep or locked.**
- **The certificate is self-signed**, so the phone has to be told to trust it
  once. Trusted network only — see [SECURITY.md](SECURITY.md).
- **Not verified on every iPhone.** The UI is exercised in a headless browser
  at a 390×844 viewport, which is not iOS Safari. Multi-touch delivery and
  four-finger gestures want real hardware.

## Layout

```
Sources/     the Mac app — listeners, validation, event injection, menu bar
Web/         the phone client — no build step, served straight from the bundle
tests/       four automated suites plus one opt-in hardware suite
scripts/     the one-time signing certificate
build.sh     compile and sign
```

## License

[MIT](LICENSE).
