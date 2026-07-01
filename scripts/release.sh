#!/usr/bin/env bash
# Publish the current version's notarized DMG as a GitHub release, which the in-app updater
# (UpdateChecker) discovers. Run AFTER make-dmg.sh.
#
#   bash scripts/release.sh                 # release the version in Info.plist
#   NOTES="..." bash scripts/release.sh     # custom release notes
#
# Requirements: gh CLI authenticated; the repo's releases must be publicly reachable for users'
# apps to see them (private repo → the anonymous API returns 404).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
TAG="v$VERSION"
DMG="dist/Tessera-$VERSION.dmg"

[ -f "$DMG" ] || { echo "✗ $DMG not found — run: bash scripts/make-dmg.sh"; exit 1; }

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "✗ Release $TAG already exists. Bump the version or delete it: gh release delete $TAG"
    exit 1
fi

echo "▸ Creating release $TAG with $DMG…"
gh release create "$TAG" "$DMG" \
    --title "Tessera $VERSION" \
    --notes "${NOTES:-Tessera $VERSION — notarized DMG attached. In-app: menu → Update Now.}"

echo "✓ Released $TAG"
VISIBILITY=$(gh repo view --json visibility --jq .visibility 2>/dev/null || echo "UNKNOWN")
if [ "$VISIBILITY" = "PRIVATE" ]; then
    echo "⚠ Repo is PRIVATE — users' apps cannot see this release."
    echo "  Make it public with: gh repo edit --visibility public --accept-visibility-change-consequences"
fi
