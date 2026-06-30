#!/usr/bin/env bash
# Build the .app bundle and (re)launch it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build-app.sh"

APP="$ROOT/dist/Tessera.app"

# Quit any running instance so the fresh build takes over.
osascript -e 'tell application "Tessera" to quit' >/dev/null 2>&1 || true
pkill -x Tessera >/dev/null 2>&1 || true
sleep 0.5

echo "▸ Launching…"
open "$APP"
echo "✓ Tessera is running — look for the grid icon in the menu bar."
