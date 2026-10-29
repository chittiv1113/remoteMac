#!/bin/bash
# Create the TLS identity the helper serves https and wss with.
#
# Why this exists: a browser only grants microphone access on a "secure
# context", and a LAN address over plain http is not one — `navigator.
# mediaDevices` is not merely blocked there, it is undefined. Encryption is
# also the gap SECURITY.md names as the app's largest, so this is worth having
# regardless of voice input.
#
# Why a CA and a leaf, rather than one self-signed certificate:
#
#   The phone has to be told to trust something, by hand, once. Apple caps a
#   server certificate at 825 days and requires the hostname in a SAN — so the
#   certificate is pinned to the address you reach the Mac on, and a DHCP lease
#   change invalidates it. With a CA, only the CA is ever trusted on the phone;
#   regenerating the leaf after an address change is then a single command here
#   and needs nothing on the phone at all.
#
# Run once:            ./scripts/make-tls-cert.sh
# After an IP change:  ./scripts/make-tls-cert.sh          (leaf only; CA kept)
# Start over:          ./scripts/make-tls-cert.sh --new-ca

set -euo pipefail
cd "$(dirname "$0")/.."

CA_NAME="remoteMac Local CA"
LEAF_NAME="remoteMac TLS"
OUT="build/tls"                 # under build/, which .gitignore already covers
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Apple rejects a server certificate valid for longer than 825 days, whoever
# signed it. Stay comfortably inside that.
LEAF_DAYS=800
CA_DAYS=3650

mkdir -p "$OUT"

# ── the names this certificate has to cover ────────────────────────────────
#
# Whatever you type in Safari must appear in the SAN list, because Apple stopped
# honouring CommonName. Collect every address the Mac can currently be reached
# on, so any of them work.

LOCAL_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s).local"
IPS=$(ifconfig | awk '/inet / && $2 != "127.0.0.1" { print $2 }' | sort -u)

ALT="DNS.1 = $LOCAL_NAME"$'\n'"DNS.2 = localhost"
ALT="$ALT"$'\n'"IP.1 = 127.0.0.1"
index=2
for ip in $IPS; do
  ALT="$ALT"$'\n'"IP.$index = $ip"
  index=$((index + 1))
done

echo "▸ certificate will cover:"
echo "    $LOCAL_NAME, localhost, 127.0.0.1"
for ip in $IPS; do echo "    $ip"; done
echo

# ── the CA ─────────────────────────────────────────────────────────────────
# Kept across runs on purpose: it is the thing your phone trusts, and replacing
# it means re-trusting by hand.

if [ "${1:-}" = "--new-ca" ]; then
  echo "▸ --new-ca: discarding the existing CA (the phone will need re-trusting)"
  rm -f "$OUT/ca.key" "$OUT/ca.crt"
fi

if [ -f "$OUT/ca.key" ] && [ -f "$OUT/ca.crt" ]; then
  echo "▸ reusing the existing CA (your phone stays trusted)"
else
  echo "▸ creating the CA…"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -keyout "$OUT/ca.key" -out "$OUT/ca.crt" -days "$CA_DAYS" \
    -subj "/CN=$CA_NAME/O=remoteMac" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    2>/dev/null
fi

# ── the leaf ───────────────────────────────────────────────────────────────

echo "▸ creating the server certificate…"
cat > "$OUT/leaf.cnf" <<CONF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $LEAF_NAME
O = remoteMac
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = critical,serverAuth
subjectAltName = @alt
[alt]
$ALT
CONF

openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout "$OUT/leaf.key" -out "$OUT/leaf.csr" \
  -config "$OUT/leaf.cnf" 2>/dev/null

openssl x509 -req -in "$OUT/leaf.csr" -sha256 -days "$LEAF_DAYS" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -extensions ext -extfile "$OUT/leaf.cnf" \
  -out "$OUT/leaf.crt" 2>/dev/null

# ── into the keychain, where the server looks for it ───────────────────────
#
# A transfer password that exists only between these two lines; random rather
# than hardcoded so a scanner cannot mistake it for a committed credential.
# `tr -dc … </dev/urandom | head -c 32` looks equivalent but is not: head exits
# first, tr dies on SIGPIPE, and `set -o pipefail` turns that into a fatal
# error. openssl is already required here and has no such trap.
P12_PASSWORD=$(openssl rand -hex 24)

openssl pkcs12 -export -out "$OUT/leaf.p12" \
  -inkey "$OUT/leaf.key" -in "$OUT/leaf.crt" -certfile "$OUT/ca.crt" \
  -name "$LEAF_NAME" -passout "pass:$P12_PASSWORD" 2>/dev/null

# Replace any previous identity, or the server could pick up a stale one that
# no longer covers the current address.
#
# Delete by SHA-1 hash, not by name: `security delete-identity -c <name>` exits
# zero without removing anything, so identities silently accumulate on every
# run. Finding the hashes first and deleting each one actually works.
security find-certificate -a -c "$LEAF_NAME" -Z "$KEYCHAIN" 2>/dev/null \
  | awk '/^SHA-1 hash:/ { print $3 }' \
  | while read -r hash; do
      security delete-identity -Z "$hash" "$KEYCHAIN" >/dev/null 2>&1 || true
    done

# ── into a keychain of its own ─────────────────────────────────────────────
#
# Deliberately NOT the login keychain. A key stored there is gated by macOS on
# two separate mechanisms — the ACL and the key partition list — and opening
# both requires your login password. Get it wrong and the keychain asks for
# that password on *every TLS handshake*, mid-connection, so the connection
# hangs until you click. Our app is signed with a local certificate and has no
# Apple team identifier, so it does not match the usual partition entries and
# keeps being asked.
#
# A dedicated keychain sidesteps all of it: this script creates it, knows its
# password because it generated it, and the helper unlocks it itself. Your
# login password is never involved.

KC_DIR="$HOME/Library/Application Support/remoteMac/tls"
KC="$KC_DIR/remotemac.keychain-db"
KC_PASSWORD_FILE="$KC_DIR/keychain-password"

mkdir -p "$KC_DIR"
chmod 700 "$KC_DIR"

KC_PASSWORD=$(openssl rand -hex 24)

# Start clean: a stale keychain holds a certificate for an address that may no
# longer be ours.
security delete-keychain "$KC" >/dev/null 2>&1 || true
rm -f "$KC"

security create-keychain -p "$KC_PASSWORD" "$KC"
# No idle lock and no lock on sleep: re-locking would make the helper fail to
# read the key exactly when it is needed.
security set-keychain-settings "$KC"
security unlock-keychain -p "$KC_PASSWORD" "$KC"

security import "$OUT/leaf.p12" -k "$KC" -P "$P12_PASSWORD" -A >/dev/null

# Allowed here without a prompt because we own this keychain and supply its
# password ourselves.
security set-key-partition-list \
  -S apple-tool:,apple:,codesign:,unsigned: \
  -s -k "$KC_PASSWORD" "$KC" >/dev/null 2>&1 || true

# The helper reads this to unlock the keychain. Owner-only, and it protects a
# LAN TLS key rather than an identity.
printf '%s' "$KC_PASSWORD" > "$KC_PASSWORD_FILE"
chmod 600 "$KC_PASSWORD_FILE"

echo "  ✓ key stored in its own keychain — your login password is not involved"

# The phone needs the CA, never the leaf's private key.
cp "$OUT/ca.crt" "$OUT/remoteMac-CA.cer"
rm -f "$OUT/leaf.csr" "$OUT/leaf.p12" "$OUT/leaf.cnf"

# ── confirm it meets Apple's rules before claiming success ─────────────────

echo
echo "▸ checking it against Apple's requirements…"
TEXT=$(openssl x509 -in "$OUT/leaf.crt" -noout -text)
fail=0

# Note `grep -q`, not `grep -qc`: -q silences the count that -c would print, so
# the two together yield an empty string and every check silently fails.
check() {
  if grep -qE "$2" <<<"$TEXT"; then echo "  ✓ $1"; else echo "  ✗ $1"; fail=1; fi
}
check "hostname is in subjectAltName (CommonName is ignored by Apple)" \
      'Subject Alternative Name'
check "extendedKeyUsage contains serverAuth" \
      'TLS Web Server Authentication'
check "signed with SHA-256" \
      'sha256WithRSA'
# LibreSSL prints "RSA Public-Key: (2048 bit)", OpenSSL 3 prints "Public-Key:".
check "RSA 2048 or stronger" \
      'Public-Key: \((2048|3072|4096) bit\)'

if [ "$LEAF_DAYS" -le 825 ]; then
  echo "  ✓ valid for $LEAF_DAYS days, within Apple's 825-day limit"
else
  echo "  ✗ $LEAF_DAYS days exceeds Apple's 825-day limit"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "❌ the certificate would not be trusted — not continuing."
  exit 1
fi

cat <<DONE

✅ TLS identity installed as "$LEAF_NAME"

   Give the CA to your phone — once, ever:

     1. AirDrop  $OUT/remoteMac-CA.cer  to the iPhone
     2. Settings › General › VPN & Device Management › install it
     3. Settings › General › About › Certificate Trust Settings
        › turn remoteMac Local CA ON

   Step 3 is the one people miss. Installing alone is not enough — iOS will
   still refuse the connection until full trust is switched on.

   Then rebuild and open https://<address>:8765 on the phone.

   If the Mac's IP later changes, re-run this script. The CA is reused, so the
   phone needs nothing.
DONE
