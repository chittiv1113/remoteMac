# Security

remoteMac sends keystrokes and mouse input into whatever application has focus
on the Mac, including Terminal. Anything that can send it commands has, in
effect, interactive access to your session. Being on the local network does not
make that harmless, so the design treats the LAN as untrusted.

## Threat model

**Assumed hostile:** any other device on the Wi-Fi network; any web page loaded
in any browser on that network, including third-party content inside an
otherwise ordinary page; anything that can resolve a name to this Mac.

**Assumed trusted:** the logged-in macOS user, and physical sight of the Mac's
menu bar (which is where the pairing PIN appears).

**Out of scope:** an attacker who already has code execution on the Mac, or
physical access to an unlocked session.

## Controls

| Control | What it stops |
|---|---|
| `Origin` checked during the WebSocket handshake | A page on another origin opening the control socket. Checked before a connection object exists. |
| `Host` checked on every HTTP request | DNS rebinding — an attacker domain resolving to this Mac still sends the wrong `Host`. |
| Explicit token, never a cookie | Cross-site WebSocket hijacking, **by construction**. No browser auto-attaches a token, so a hostile page can open the socket but cannot authenticate it. |
| PIN is bootstrap-only, rate-limited | Brute force. Five free attempts, then exponential backoff to 15 minutes. The lockout covers the correct PIN too, so an attacker cannot race a legitimate pairing. |
| 256-bit session token, SHA-256 stored at `0600` | A stolen state file being replayed as a credential. |
| Command validation, reject-don't-clamp | Out-of-range deltas, unknown message types, oversized text, attacker-chosen key codes. |
| Two size caps, not one | An input command is capped at 4 KB — a pointer packet is ~60 bytes, so nothing legitimate is close. The transport ceiling is larger only because two user-initiated messages genuinely are (a shortcut-deck write and the installed-app list, both carrying app icons), and the exemption is granted by message type rather than by size. |
| Key-code allowlist | Any integer reaching `CGKeyCode`. |
| Shortcut allowlist, resolved by id | Arbitrary `open`. The phone sends an id; the Mac resolves it against its own validated deck. Targets must be `https:` or an installed app path, re-checked at run time. |
| `NWProtocolWebSocket` rather than hand-written framing | Malformed frames. Framing, masking, fragmentation and size limits are Apple's code, not ours — and this is the one place that parses attacker-controlled bytes before any check has run. |
| Single-controller lease | A second device silently taking over mid-session. |
| Token-bucket rate limit (300/s) | Command floods. |
| Pause / Revoke in the menu bar | Anything in progress, immediately. Both release held buttons and modifiers. |
| TLS on both listeners | Passive eavesdropping and tampering on the Wi-Fi. The page and the control socket are `https`/`wss`; the accepted `Origin` follows the scheme, so a plaintext page cannot drive an encrypted socket. |

## What this does *not* protect against

**The certificate authority is self-signed, and you trust it by hand.** Traffic
is encrypted — see the TLS row above — but the trust anchor is a CA this Mac
generated, installed on the phone manually. That is sound on a home network
where you control both ends, and it is not a substitute for a public CA. Anyone
who can get you to install *their* CA profile can intercept you, which is true
of any device but worth saying out loud.

**The private key is readable by any process running as you.** It is kept in a
dedicated keychain rather than your login keychain, and the keychain's password
sits next to it at mode `0600`. That protects it from other accounts, not from
code already running as you — which is already out of scope above. The key
authenticates a home-network service; it is not an identity.

**Use this on a trusted home network only.** Do not port-forward it and do not
expose it to the internet. Encryption raises the bar against passive
eavesdropping on the Wi-Fi; it does not make the service safe to publish.

**A paired phone is a trusted device.** If it is lost or borrowed, use *Revoke
all devices* in the menu bar. Note what pairing grants: a paired device can
already type anything into your session, so the controls above are about
keeping *unpaired* devices out, not about limiting a paired one.

**Accessibility permission is powerful.** Granting it lets this app synthesize
input anywhere. Only grant it to a binary you built yourself, from source you
have read.

## What is deliberately absent

No screen capture, no file transfer, no shell or command-execution endpoint, no
macro engine, no cloud service, no analytics, no third-party scripts, no CDN
requests. Typing into Terminal works because keystrokes are synthesized into
whatever app has focus — there is no code path anywhere that executes a command
on the phone's behalf.

## Privacy

Keystrokes, typed text and key codes are never logged — not to a file, not to
the system log, not to the menu bar. The menu bar shows a count and a
content-free label (`key`, `text`, `click`), which is enough to tell whether
input is arriving and not enough to reconstruct any of it.

The Mac reports *that* a text field has focus so the phone can raise its
keyboard view, and nothing more: `FocusWatcher` reads the focused element's
accessibility **role** only — never its value, title, or surrounding text. The
single fact that crosses the wire is a boolean. Reading field contents is what
would make this a keylogger, so it is not read.

Persistent state is limited to `~/Library/Application Support/remoteMac/`:
`deck.json` (your shortcut buttons) and `session.json` (SHA-256 hashes of paired
device tokens, mode `0600`). The PIN is regenerated at every launch and never
written to disk.

## Reporting

This is a personal project, not a maintained product, and it carries no
security guarantee. If you find a flaw, please open an issue. Do not include a
working exploit against someone else's machine in a public report.

If the flaw lets a non-paired device on the network inject input, that is the
class of bug this design exists to prevent — say so plainly in the title so it
is not missed.

## Verification

The controls in the table are covered by `./tests/run.sh` — 299 checks across
four suites, including malformed and oversized frames, every rejection path, and
a browser-level pass that pairs and drives the real UI.

These suites never synthesize real input: event injection is replaced by a
capture closure, so a test cannot move the cursor or type. The one suite that
does inject (`tests/injection`) is opt-in, is not part of `run.sh`, and
re-checks which application has focus before every keystroke batch.
