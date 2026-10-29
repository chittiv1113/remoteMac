#!/bin/bash
# Build the Mac helper into a .app bundle using only Xcode Command Line Tools.
#
# No Xcode, no xcodegen, no Homebrew. Verified on macOS 15.7.5 with the Swift
# 6.1.2 toolchain that ships with the Command Line Tools. The Info.plist is
# generated below rather than kept as a file, so there is one build path and
# nothing to keep in sync.
#
# Usage:
#   ./build.sh                      # build + sign (real identity if one exists)
#   CODESIGN_IDENTITY="..." ./build.sh
#
# This script does NOT launch the helper. Starting it opens a listening port on
# the LAN; do that deliberately, not as a side effect of building.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="remoteMac"
BUNDLE_ID="com.remotemac.helper"   # also the UserDefaults domain — changing it resets settings
EXE="remoteMac"
VERSION="0.2.0"
MIN_MACOS="13.0"

APP="build/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "▸ compiling…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
swiftc -O \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macos$MIN_MACOS" \
  -framework AppKit -framework SwiftUI \
  Sources/*.swift \
  -o "$CONTENTS/MacOS/$EXE"

echo "▸ copying web assets…"
# AssetCache resolves these by name through Bundle.main, so they must sit flat
# in Resources/ rather than in a Web/ subdirectory.
cp Web/* "$CONTENTS/Resources/"

echo "▸ writing Info.plist…"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>          <string>en</string>
	<key>CFBundleDisplayName</key>                <string>$APP_NAME</string>
	<key>CFBundleExecutable</key>                 <string>$EXE</string>
	<key>CFBundleIdentifier</key>                 <string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
	<key>CFBundleName</key>                       <string>$APP_NAME</string>
	<key>CFBundlePackageType</key>                <string>APPL</string>
	<key>CFBundleShortVersionString</key>         <string>$VERSION</string>
	<key>CFBundleVersion</key>                    <string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>             <string>$MIN_MACOS</string>
	<key>LSUIElement</key>                        <true/>
	<key>NSLocalNetworkUsageDescription</key>     <string>Accepts browser connections from your phone on the same Wi-Fi network.</string>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null

echo "▸ signing…"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # A self-signed local certificate first: it is not "valid" per policy (no
  # trusted root), so it only appears without -v — but codesign accepts it, and
  # it is what keeps the app's identity stable across rebuilds.
  if security find-identity -p codesigning 2>/dev/null | grep -qF "remoteMac Local Signing"; then
    IDENTITY="remoteMac Local Signing"
  else
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
      | awk '/Apple Development|Developer ID|Mac Developer/ { print $2; exit }')
  fi
fi

if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "  signed with $IDENTITY"
else
  codesign --force --sign - "$APP"
  cat <<'WARN'
  signed ad-hoc (no code-signing identity found).

  Heads up: macOS ties the Accessibility permission to the code signature, and
  an ad-hoc signature is derived from the binary's contents — so every rebuild
  looks like a different app and silently voids the grant. The entry stays
  switched on in System Settings while matching nothing, and injected events
  are dropped with no error logged anywhere.

  Fix it once:

      ./scripts/make-signing-cert.sh

  then rebuild. The identity becomes stable and the grant survives rebuilds.
WARN
fi

echo
echo "✅ $APP"
echo "   Not started. To run it: open \"$APP\""
echo "   It will listen on port 8765 once running."
