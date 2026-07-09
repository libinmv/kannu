#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/build/Build/Products/Release/Kannu.app}"
DMG_PATH="${2:-$ROOT_DIR/build/Kannu.dmg}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kannu-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$DMG_PATH")"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "Kannu" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

echo "Created $DMG_PATH"
