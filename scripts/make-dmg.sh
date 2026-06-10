#!/bin/sh
# Build a distributable Dustpan DMG. Universal Release build → DMG; signing
# and notarization happen only when a Developer ID certificate is present,
# and the script says plainly which kind of artifact it produced.
#
# Usage: scripts/make-dmg.sh [output-dir]
#   NOTARY_PROFILE=<profile>  optional: a `notarytool store-credentials`
#                             profile name to also notarize + staple.
#
# No hardcoded paths: everything resolves from this script's location and
# xcodebuild's own build settings.

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR=${1:-"$REPO_DIR/dist"}
PROJECT="$REPO_DIR/Dustpan.xcodeproj"
SCHEME=Dustpan

echo "==> Release build (universal)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release build | tail -1

BUILT=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')
APP="$BUILT/$SCHEME.app"
[ -d "$APP" ] || { echo "ERROR: $APP not found"; exit 1; }

echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/$SCHEME")"

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "0.0")
DMG="$OUT_DIR/Dustpan-$VERSION.dmg"
mkdir -p "$OUT_DIR"

# Developer ID is the gate between "shareable artifact" and "local test disk
# image". We never pretend an unsigned build is distributable.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/{print $2; exit}') || IDENTITY=""

if [ -n "$IDENTITY" ]; then
  echo "==> Signing with: $IDENTITY"
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
  codesign --verify --strict "$APP" && echo "    signature verified"
else
  echo "==> NO Developer ID Application certificate found."
  echo "    Producing an UNSIGNED dmg for local testing only — Gatekeeper"
  echo "    will block it on other Macs. Get a Developer ID cert from your"
  echo "    Apple Developer account, then re-run."
fi

echo "==> Creating $DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Dustpan" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$IDENTITY" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "==> Notarized and stapled."
elif [ -n "$IDENTITY" ]; then
  echo "==> Signed but NOT notarized (set NOTARY_PROFILE=<name> to notarize)."
fi

echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
[ -n "$IDENTITY" ] || echo "    Reminder: this artifact is unsigned — do not distribute."
