#!/usr/bin/env bash
# Step 2 of using your Apple Developer certificate: install the .cer you downloaded from Apple,
# then verify codesign can see the identity.
#
# Usage:  bash scripts/install-cert.sh ~/Downloads/developerID_application.cer
set -euo pipefail

CER="${1:-}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ -z "$CER" ] || [ ! -f "$CER" ]; then
    echo "Usage: bash scripts/install-cert.sh <path-to-downloaded.cer>"
    exit 1
fi

echo "▸ Installing $CER into your login keychain…"
security import "$CER" -k "$KEYCHAIN" 2>/dev/null || echo "  (already installed — continuing)"

# Developer ID certs chain through Apple's WWDR intermediate. If it's missing, codesign fails with
# "unable to build chain". Install it if absent.
if ! security find-certificate -c "Apple Worldwide Developer Relations" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "▸ Fetching Apple's WWDR intermediate certificate…"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    if curl -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$TMP/wwdr.cer"; then
        security import "$TMP/wwdr.cer" -k "$KEYCHAIN" 2>/dev/null || true
    else
        echo "  (couldn't download WWDR automatically; if signing fails, install it from"
        echo "   https://www.apple.com/certificateauthority/ )"
    fi
fi

echo
echo "▸ Code-signing identities now available:"
security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /'

if security find-identity -v -p codesigning 2>/dev/null | grep -qE "Developer ID Application|Apple Development|Apple Distribution"; then
    echo
    echo "✓ Success — a stable Apple identity is installed."
    echo "  Now rebuild and grant Accessibility ONE final time; it will persist from here on:"
    echo "      tccutil reset Accessibility com.fileread.Tessera"
    echo "      bash scripts/run.sh"
else
    echo
    echo "⚠︎ No valid identity yet. Make sure the private key from make-csr.sh is in the same"
    echo "  keychain and that you downloaded the matching certificate."
fi
