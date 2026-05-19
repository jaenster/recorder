#!/bin/bash
# One-time setup: create a self-signed code-signing identity in the login
# keychain so TCC permission grants survive rebuilds of Recorder.app.
#
# After running this once, build.sh signs with "Recorder Dev". Rebuilds
# keep the same code-signing identity, so the TCC requirement stored when
# you first grant Microphone / Screen Recording / Speech Recognition stays
# satisfied across new builds — no more re-prompts.
set -euo pipefail

IDENTITY="Recorder Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "Identity '$IDENTITY' already exists. Done."
    exit 0
fi

echo "==> generating private key + self-signed code-signing cert"
openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints   = critical, CA:FALSE
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

openssl req -x509 -new -key "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" -sha256 2>/dev/null

# OpenSSL 3 defaults to AES-256-CBC + SHA-256 for PKCS12, which Apple's
# Security framework can't read. Force the legacy RC2-40 / SHA-1 format.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/bundle.p12" -name "$IDENTITY" \
    -passout pass:dev 2>/dev/null

echo "==> importing into login keychain"
security import "$TMP/bundle.p12" \
    -k "$KEYCHAIN" \
    -P dev \
    -T /usr/bin/codesign \
    -A >/dev/null

echo "==> trusting cert for code signing"
# Add the cert separately so it shows up in find-identity and is trusted
# for code signing. Using -d (admin) requires sudo; user keychain works
# fine for ad-hoc/local dev.
security add-trusted-cert -k "$KEYCHAIN" \
    -p codeSign "$TMP/cert.pem" 2>/dev/null || true

echo "==> verifying"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "Identity '$IDENTITY' is ready."
else
    echo "WARNING: identity not visible to codesign yet."
    echo "Try: security unlock-keychain $KEYCHAIN"
    exit 1
fi
