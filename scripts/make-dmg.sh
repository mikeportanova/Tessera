#!/usr/bin/env bash
# Build → notarize → package Tessera into a notarized, stapled DMG you can hand to anyone.
# The result opens on any Mac with no "unidentified developer" / Gatekeeper warning.
#
# Prereq (one-time): a Developer ID cert (scripts/install-cert.sh) and notarytool credentials
#   xcrun notarytool store-credentials "Tessera" --apple-id ... --team-id Y96A8JN9HF --password ...
#
# Usage:  bash scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Tessera.app"
PROFILE="${NOTARY_PROFILE:-Tessera}"

# 1. Build (signed + hardened), then notarize + staple the .app itself.
bash "$ROOT/scripts/notarize.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"
DMG="$ROOT/dist/Tessera-$VERSION.dmg"

# 2. Stage the app + a drag-to-Applications shortcut, then build a compressed DMG.
echo "▸ Building DMG…"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Tessera" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

# 3. Notarize the DMG and staple the ticket so it validates offline.
echo "▸ Notarizing the DMG (a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "▸ Verifying…"
spctl --assess --type open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/    /' || true
echo "✓ Ready to share: $DMG"
