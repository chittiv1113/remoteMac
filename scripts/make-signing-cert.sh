#!/bin/bash
# Create a self-signed code-signing identity so the app's code identity is
# stable across rebuilds.
#
# Why this exists: macOS ties the Accessibility permission to the app's code
# signature. An ad-hoc signature (`codesign -s -`) is derived from the binary's
# contents, so every rebuild produces a different identity and silently voids
# the grant — the entry in System Settings stays switched on but no longer
# matches, and events are dropped with no error anywhere.
#
# Signing with a certificate instead pins the identity to the certificate, so
# the grant survives rebuilds. The certificate is self-signed and lives only in
# your login keychain; it is not a developer account and costs nothing.
#
# Run once:  ./scripts/make-signing-cert.sh
# Then:      CODESIGN_IDENTITY="remoteMac Local Signing" ./build.sh

set -euo pipefail

NAME="${1:-remoteMac Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
  echo "✓ '$NAME' already exists — nothing to do."
  echo
  echo "Build with it:"
  echo "    CODESIGN_IDENTITY=\"$NAME\" ./build.sh"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Transfer password for the PKCS#12 file, which exists for the few lines
# between export and import and is then deleted with $TMP. Random rather than
# hardcoded: a literal here would read like a committed credential, and secret
# scanners cannot tell the difference.
# `tr -dc … </dev/urandom | head -c 32` looks equivalent but is not: head exits
# first, tr dies on SIGPIPE, and `set -o pipefail` turns that into a fatal
# error. openssl is already required here and has no such trap.
P12_PASSWORD=$(openssl rand -hex 24)

echo "▸ generating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

openssl pkcs12 -export -out "$TMP/identity.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout "pass:$P12_PASSWORD" 2>/dev/null

echo "▸ importing into your login keychain…"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Let codesign use the key without a prompt on every build. This needs the
# keychain password; if it is skipped, macOS prompts once instead and
# "Always Allow" has the same effect.
if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
else
  echo "  note: macOS may prompt for your login password the first time you build."
  echo "        Choose \"Always Allow\" and it will not ask again."
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
  echo
  echo "✅ created '$NAME'"
  echo
  echo "Next:"
  echo "    CODESIGN_IDENTITY=\"$NAME\" ./build.sh"
  echo
  echo "Then grant Accessibility once. Because the identity is now stable, the"
  echo "grant will survive future rebuilds."
else
  echo
  echo "❌ the identity was not created. Fall back to Keychain Access:"
  echo "   Certificate Assistant › Create a Certificate…"
  echo "   Name: $NAME   Identity Type: Self Signed Root   Type: Code Signing"
  exit 1
fi
