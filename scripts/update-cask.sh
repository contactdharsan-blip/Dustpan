#!/usr/bin/env bash
# Refresh Casks/dustpan.rb from a built DMG: set version + sha256 to match the
# artifact you're about to publish. Run this after make-dmg.sh produces the
# notarized release DMG, before submitting the Cask to a tap.
#
# Usage: scripts/update-cask.sh [path/to/Dustpan-X.Y.Z.dmg]
#   default: the newest dist/Dustpan-*.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK="$ROOT/Casks/dustpan.rb"

DMG="${1:-$(ls -t "$ROOT"/dist/Dustpan-*.dmg 2>/dev/null | head -1 || true)}"
[ -n "$DMG" ] && [ -f "$DMG" ] || { echo "No DMG found (build one with scripts/make-dmg.sh)"; exit 1; }

# Version from the filename: Dustpan-<version>.dmg
BASE="$(basename "$DMG")"
VERSION="${BASE#Dustpan-}"; VERSION="${VERSION%.dmg}"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

echo "DMG:     $DMG"
echo "version: $VERSION"
echo "sha256:  $SHA"

# In-place rewrite of just the version + sha256 lines (BSD sed -i needs '').
sed -i '' -E "s/^  version \"[^\"]*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' -E "s/^  sha256 \"[0-9a-f]{64}\"/  sha256 \"$SHA\"/" "$CASK"

echo "Updated $CASK"
echo "Next: \`brew audit --new --cask $CASK\` then submit to your tap."
