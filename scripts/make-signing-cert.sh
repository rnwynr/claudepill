#!/usr/bin/env bash
# Creates a self-signed code-signing certificate in your login keychain, so every build of
# Claude Pill carries the same signature and macOS keeps its Screen Recording permission.
# Only needed if you don't have an "Apple Development" certificate from Xcode.
set -euo pipefail

NAME="Claude Pill Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "✓ \"$NAME\" already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# The system LibreSSL writes a PKCS#12 that `security import` can read (Homebrew's OpenSSL 3 doesn't by default).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:claudepill
security import "$TMP/id.p12" -k "$KEYCHAIN" -P claudepill -T /usr/bin/codesign >/dev/null

echo "✓ Created \"$NAME\" in your login keychain."
echo "  If codesign asks to use the key, click \"Always Allow\"."
