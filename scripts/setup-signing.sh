#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity for Tessera, once.
#
# Why: macOS pins Accessibility / Screen Recording grants to an app's code signature. An ad-hoc
# signature (`codesign -s -`) changes on every rebuild, so macOS keeps treating each build as a new
# app and re-prompts forever — the entry you toggled on is a stale previous build. A self-signed
# identity is stable across rebuilds, so you grant permission ONCE and it sticks.
#
# Run this a single time:   bash scripts/setup-signing.sh
# Then always build with:    bash scripts/build-app.sh   (it auto-detects the identity)
#
# You may be asked for your login password / to allow keychain access — that's expected.
set -euo pipefail

IDENTITY_NAME="Tessera Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "✓ Signing identity \"$IDENTITY_NAME\" already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Generating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
    -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass: -name "$IDENTITY_NAME" >/dev/null 2>&1

echo "▸ Importing into your login keychain (allow codesign to use it)…"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign -A

echo "▸ Trusting the certificate for code signing…"
# User-domain trust so codesign considers the identity valid. May prompt for your password.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || \
    echo "  (trust step skipped/declined — codesign may still work; see note below)"

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "✓ Done. \"$IDENTITY_NAME\" is ready. Now run:  bash scripts/run.sh"
    echo "  Grant Accessibility once more and it will persist across future rebuilds."
else
    echo "⚠︎ The identity isn't showing as valid yet. If builds still fall back to ad-hoc,"
    echo "  open Keychain Access → login → Certificates → \"$IDENTITY_NAME\" → Trust →"
    echo "  'Code Signing: Always Trust'."
fi
