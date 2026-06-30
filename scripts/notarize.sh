#!/usr/bin/env bash
# Notarize Tessera.app with Apple and staple the ticket, so it runs on other Macs without
# Gatekeeper warnings. Requires the app to be signed with your Developer ID + hardened runtime
# (scripts/build-app.sh does this automatically when a Developer ID identity is present).
#
# One-time credential setup (stores an app-specific password in your keychain):
#   xcrun notarytool store-credentials "Tessera" \
#       --apple-id "you@example.com" --team-id "Y96A8JN9HF" --password "<app-specific-password>"
#   (Create an app-specific password at https://account.apple.com → Sign-In & Security.)
#
# Then just run:  bash scripts/notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Tessera.app"
ZIP="$ROOT/dist/Tessera.zip"
PROFILE="${NOTARY_PROFILE:-Tessera}"

# 1. Build (signed + hardened) if needed.
if [ ! -d "$APP" ]; then
    echo "▸ No build found — building first…"
    bash "$ROOT/scripts/build-app.sh"
fi

# 2. Sanity-check the signature is Developer ID with hardened runtime.
# (Capture the output first — piping into `grep -q` under `set -o pipefail` would report a false
# failure: grep closes the pipe early and codesign dies with SIGPIPE.)
SIGINFO="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
if ! grep -q "Authority=Developer ID Application" <<<"$SIGINFO"; then
    echo "✗ $APP is not signed with a Developer ID identity — notarization can't proceed."
    echo "  Install your Developer ID cert (scripts/install-cert.sh) and rebuild, then retry."
    exit 1
fi
if ! grep -q "runtime" <<<"$SIGINFO"; then
    echo "▸ Re-signing with the hardened runtime (required for notarization)…"
    bash "$ROOT/scripts/build-app.sh"
fi

# 3. Confirm credentials exist.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat <<EOF
✗ No notarytool credentials found for profile "$PROFILE".

Set them up once (you'll need an app-specific password from https://account.apple.com):

  xcrun notarytool store-credentials "$PROFILE" \\
      --apple-id "<your-apple-id-email>" \\
      --team-id "Y96A8JN9HF" \\
      --password "<app-specific-password>"

Then re-run: bash scripts/notarize.sh
EOF
    exit 1
fi

# 4. Zip (notarytool wants an archive), submit, and wait for the result.
echo "▸ Zipping the app…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# 5. Staple the ticket onto the .app so it validates offline.
echo "▸ Stapling the notarization ticket…"
xcrun stapler staple "$APP"

echo "▸ Verifying Gatekeeper acceptance…"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true

rm -f "$ZIP"
echo "✓ Notarized and stapled: $APP — ready to distribute."
