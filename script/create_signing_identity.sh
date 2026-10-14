#!/usr/bin/env bash
# Creates a self-signed code-signing certificate in the login keychain (once).
# Signing every build with the same certificate keeps macOS privacy permissions
# (Accessibility) valid across rebuilds; ad-hoc signatures change with every build.
set -euo pipefail

IDENTITY="Nogrammerly Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Signing identity \"$IDENTITY\" already exists."
  exit 0
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nogrammerly-signing.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
PASSWORD="$(uuidgen)"

cat >"$WORK_DIR/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK_DIR/cert.conf" \
  -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" 2>/dev/null
# Use SHA1/3DES PKCS#12 so the macOS keychain can import it (OpenSSL 3 defaults to AES, which it rejects).
openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" -name "$IDENTITY" \
  -out "$WORK_DIR/identity.p12" -passout "pass:$PASSWORD" 2>/dev/null
# -T lets codesign use the key without a keychain prompt on every build.
security import "$WORK_DIR/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
echo "Created signing identity \"$IDENTITY\" in the login keychain."
