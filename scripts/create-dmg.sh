#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <path-to-Kannu.app> <output-dmg-path>" >&2
  exit 1
fi

APP_PATH="$1"
DMG_PATH="$2"

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

hdiutil create \
  -volname "Kannu" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# Sign the disk image itself. The app inside is already Developer ID signed and the DMG gets a
# stapled notarization ticket from notarize-dmg.sh, but an unsigned DMG still has nothing for a
# signature check to evaluate: `spctl -a -t open` reports "no usable signature" on a released
# build. Signing must happen here, before notarization — stapling a signed DMG afterwards leaves
# the signature intact.
#
# Optional by design: releases run with a Developer ID cert in the keychain (CI installs one into
# a temporary keychain), while a local `build-dmg.sh` run usually has none. Skip rather than fail
# so an unsigned DMG is still produced for local testing.
SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')}"

if [ -n "$SIGN_IDENTITY" ]; then
  echo "Signing $DMG_PATH as $SIGN_IDENTITY"
  codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
else
  echo "No Developer ID Application identity found; leaving $DMG_PATH unsigned." >&2
fi

echo "Created $DMG_PATH"
