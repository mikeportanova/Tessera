#!/usr/bin/env bash
# Build Tessera and assemble a runnable .app bundle (no Xcode required).
#
# Why a bundle? A bare SwiftPM binary can't carry an Info.plist, so it can't be an LSUIElement
# agent and macOS TCC treats every run as a different "app". Wrapping the binary in a signed
# .app gives us a stable bundle id + code signature, which is what the Accessibility / Screen
# Recording grants are pinned to.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Tessera"
CONFIG="release"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

cd "$ROOT"

echo "▸ Building ($CONFIG)…"
# If full Xcode is the active toolchain but its license hasn't been accepted, `swift build` fails
# with a license error. Retry on the Command Line Tools toolchain so we never need
# `sudo xcodebuild -license`. (To use Xcode instead, run: sudo xcodebuild -license accept)
ERRLOG="$(mktemp)"
# Clean up the temp log on ANY exit — including the CLT-retry path failing under `set -e`.
trap 'rm -f "$ERRLOG"' EXIT
if ! swift build -c "$CONFIG" 2>"$ERRLOG"; then
    if grep -qi "license" "$ERRLOG" && [ -d /Library/Developer/CommandLineTools ]; then
        echo "▸ Xcode license not accepted — retrying with the Command Line Tools toolchain."
        export DEVELOPER_DIR=/Library/Developer/CommandLineTools
        swift build -c "$CONFIG"
    else
        cat "$ERRLOG" >&2
        exit 1
    fi
fi

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_PATH/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# Prefer a STABLE identity so Accessibility/Screen Recording grants persist across rebuilds.
# Order of preference: a Developer ID, then our self-signed "Tessera Self-Signed" (from
# scripts/setup-signing.sh), then ad-hoc as a last resort.
IDENTITY=""
ALL_IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
# Preference: Developer ID (distributable/notarizable) → Apple Development (from Xcode sign-in) →
# our self-signed dev identity. Any of these is stable, so TCC grants persist across rebuilds.
for pattern in "Developer ID Application" "Apple Development" "Apple Distribution" "Tessera Self-Signed"; do
    if echo "$ALL_IDS" | grep -q "$pattern"; then
        IDENTITY="$(echo "$ALL_IDS" | grep "$pattern" | head -1 | sed -E 's/.*"(.*)"/\1/')"
        break
    fi
done

if [ -n "$IDENTITY" ]; then
    echo "▸ Code signing with stable identity: $IDENTITY"
    # Developer ID gets the hardened runtime + secure timestamp so the build is notarizable.
    # (Hardened runtime doesn't impede the Accessibility/Screen Recording APIs Tessera uses.)
    if echo "$IDENTITY" | grep -q "Developer ID"; then
        codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
    else
        codesign --force --deep --sign "$IDENTITY" "$APP"
    fi
else
    echo "▸ Ad-hoc code signing (UNSTABLE)…"
    echo "  ⚠︎ Permissions will NOT persist across rebuilds with an ad-hoc signature."
    echo "    Run 'bash scripts/setup-signing.sh' once for a stable identity."
    codesign --force --deep --sign - "$APP"
    # If you must stay ad-hoc, reset stale grants after each rebuild:
    #   tccutil reset Accessibility com.fileread.Tessera
    #   tccutil reset ScreenCapture com.fileread.Tessera
fi

echo "✓ Built $APP"
