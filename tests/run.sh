#!/bin/bash
# Run every suite: Swift unit, Swift integration, JS logic, and browser checks.
#
# RemoteMacApp.swift is excluded from the test builds because it carries @main,
# which conflicts with a test runner's own top-level code.
set -uo pipefail
cd "$(dirname "$0")/.."

# A bare test binary has no Bundle.main resources, so point the asset loader at
# the repo copy of the web files. Keep test state out of Application Support.
export REMOTEMAC_WEB_DIR="$PWD/Web"
TMP=$(mktemp -d)
export REMOTEMAC_STATE_DIR="$TMP/state"
mkdir -p "$REMOTEMAC_STATE_DIR"

HARNESS_PID=""
cleanup() {
  [ -n "$HARNESS_PID" ] && kill "$HARNESS_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

SOURCES=$(find Sources -name '*.swift' ! -name 'RemoteMacApp.swift')
SDK=$(xcrun --show-sdk-path)
TARGET="$(uname -m)-apple-macos13.0"
status=0

build() {
  swiftc -sdk "$SDK" -target "$TARGET" -framework AppKit -framework SwiftUI \
    $SOURCES "$1" -o "$2" || return 1
}

echo "════════ Swift unit tests ════════"
if build tests/unit/main.swift "$TMP/unit"; then "$TMP/unit" || status=1
else echo "  build failed"; status=1; fi

echo
echo "════════ Swift integration tests ════════"
if build tests/integration/main.swift "$TMP/integration"; then "$TMP/integration" || status=1
else echo "  build failed"; status=1; fi

echo
echo "════════ JS logic tests ════════"
node --test tests/logic.test.js || status=1

echo
echo "════════ Browser checks ════════"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
  echo "  skipped — Google Chrome not installed"
elif ! command -v node >/dev/null; then
  echo "  skipped — node not installed"
elif ! build tests/harness/main.swift "$TMP/harness"; then
  echo "  harness build failed"; status=1
else
  "$TMP/harness" > "$TMP/harness.log" 2>&1 &
  HARNESS_PID=$!
  for _ in $(seq 1 40); do grep -q READY "$TMP/harness.log" 2>/dev/null && break; sleep 0.2; done
  PIN=$(grep '^PIN ' "$TMP/harness.log" | awk '{print $2}')
  if [ -z "$PIN" ]; then
    echo "  harness did not start:"; sed 's/^/    /' "$TMP/harness.log"; status=1
  else
    # Screenshots land in a throwaway directory unless REMOTEMAC_SHOTS asks
    # for somewhere that survives the run.
    SHOTS="${REMOTEMAC_SHOTS:-$TMP/shots}"
    node tests/ui-check.js http://127.0.0.1:18765 "$PIN" --shots "$SHOTS" || status=1
  fi
  kill "$HARNESS_PID" 2>/dev/null; HARNESS_PID=""
fi

echo
if [ "$status" -eq 0 ]; then echo "✅ all suites passed"; else echo "❌ failures above"; fi
exit $status
