#!/usr/bin/env bash
# Step 1 of using your Apple Developer certificate (no Xcode needed).
#
# Generates a private key + a Certificate Signing Request (CSR), and imports the private key into
# your login keychain. You then upload the CSR to developer.apple.com to get a certificate, and run
# scripts/install-cert.sh with the downloaded file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/signing"           # gitignored; holds your key + CSR
mkdir -p "$DIR"

KEY="$DIR/tessera_signing_key.pem"
CSR="$DIR/tessera.certSigningRequest"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
EMAIL="${1:-mike@fileread.com}"

if [ -f "$KEY" ]; then
    echo "✓ A signing key already exists at $KEY — reusing it."
else
    echo "▸ Generating a 2048-bit private key…"
    openssl genrsa -out "$KEY" 2048 >/dev/null 2>&1
fi

echo "▸ Building the Certificate Signing Request…"
openssl req -new -key "$KEY" -out "$CSR" \
    -subj "/emailAddress=$EMAIL/CN=Tessera Developer/C=US" >/dev/null 2>&1

echo "▸ Importing the private key into your login keychain (lets codesign use it)…"
security import "$KEY" -k "$KEYCHAIN" -T /usr/bin/codesign -A 2>/dev/null || \
    echo "  (key may already be imported — that's fine)"

cat <<EOF

✓ CSR ready:  $CSR

Next:
  1. Go to https://developer.apple.com/account/resources/certificates/add
  2. Choose a certificate type:
       • "Developer ID Application"  → best (lets you notarize & share the app)
                                        requires Account Holder/Admin role
       • "Apple Development"         → fine for just stopping the permission prompts
  3. Upload the CSR file above when asked.
  4. Download the resulting .cer file.
  5. Run:  bash scripts/install-cert.sh ~/Downloads/<the-file>.cer
EOF
