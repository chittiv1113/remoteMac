# Running remoteMac at login

Pairing is required and `Origin`/`Host` are validated, so leaving this running
is reasonable on a trusted home network. Be clear about what it means: the
service is reachable on your LAN whenever you are logged in, and traffic is
encrypted with a certificate you trusted by hand rather than a public CA. See
[SECURITY.md](SECURITY.md).

A **user LaunchAgent**, not a daemon: injecting input needs the Accessibility
permission, which only works inside a logged-in GUI session.

## Install

```bash
./build.sh
rm -rf ~/Applications/remoteMac.app
ditto "build/remoteMac.app" ~/Applications/remoteMac.app
```

Grant Accessibility once, then write the LaunchAgent:

```bash
cat > ~/Library/LaunchAgents/com.remotemac.helper.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>              <string>com.remotemac.helper</string>
	<key>ProgramArguments</key>
	<array>
		<string>$HOME/Applications/remoteMac.app/Contents/MacOS/remoteMac</string>
	</array>
	<key>RunAtLoad</key>          <true/>
	<key>KeepAlive</key>          <true/>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.remotemac.helper.plist
```

`RunAtLoad` starts it at login; `KeepAlive` restarts it if it dies.

The address to open on your phone is in the menu bar. It prefers the mDNS name
(`https://$(scutil --get LocalHostName).local:8765`) because that survives a DHCP
lease change, and falls back to the IP when mDNS is not resolving.

## Manage

```bash
PLIST=~/Library/LaunchAgents/com.remotemac.helper.plist
GUI="gui/$(id -u)"

launchctl print "$GUI/com.remotemac.helper" | grep -E "state|pid"   # status
launchctl bootout "$GUI" "$PLIST"                                   # stop, no restart
launchctl bootstrap "$GUI" "$PLIST"                                 # start
launchctl kickstart -k "$GUI/com.remotemac.helper"                  # restart
```

To uninstall: `launchctl bootout` as above, then delete the plist and the app.

## Notes

- The Mac must be **awake and on the same Wi-Fi**. A sleeping Mac stops
  serving; a LaunchAgent is not a wake-on-demand solution.
- **Don't run a second copy** while the agent is loaded. Port 8765 collides and
  the second listener fails — the menu bar shows "Not running".
- After a reboot it starts at **login**, not at boot.
- Rebuilding into `~/Applications` needs a `launchctl kickstart` to pick up the
  new binary.
