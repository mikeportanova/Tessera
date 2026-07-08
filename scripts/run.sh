#!/usr/bin/env bash
# Build the .app bundle and (re)launch it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build-app.sh"

APP="$ROOT/dist/Tessera.app"

# Quit any running instance so the fresh build takes over. Only bother if one is actually
# running, and poll for the process to exit instead of racing it with a fixed sleep.
wait_for_exit() {
    # Poll up to ~5s (50 × 0.1s) for the process to disappear; returns 0 once gone.
    for _ in $(seq 1 50); do
        pgrep -x Tessera >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    return 1
}

if pgrep -x Tessera >/dev/null 2>&1; then
    osascript -e 'tell application "Tessera" to quit' >/dev/null 2>&1 || true
    if ! wait_for_exit; then
        echo "▸ Graceful quit timed out — force-killing."
        pkill -x Tessera >/dev/null 2>&1 || true
        wait_for_exit || { echo "✗ Tessera refused to exit; aborting relaunch." >&2; exit 1; }
    fi
fi

echo "▸ Launching…"
open "$APP"
echo "✓ Tessera is running — look for the grid icon in the menu bar."
