#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <path-to-dmg> <updates-directory> <download-url-prefix> [sparkle-bin-dir]" >&2
  exit 1
fi

DMG_PATH="$1"
UPDATES_DIR="$2"
DOWNLOAD_URL_PREFIX="$3"
SPARKLE_BIN_DIR="${4:-}"

if [ ! -f "$DMG_PATH" ]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

mkdir -p "$UPDATES_DIR"

STAGING_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

DMG_NAME="$(basename "$DMG_PATH")"
cp "$DMG_PATH" "$STAGING_DIR/$DMG_NAME"

if [ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]; then
  if [ -z "$SPARKLE_BIN_DIR" ]; then
    echo "Sparkle bin directory is required when SPARKLE_EDDSA_PRIVATE_KEY is set." >&2
    exit 1
  fi

  KEY_FILE="$(mktemp)"
  printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY" > "$KEY_FILE"
  "$SPARKLE_BIN_DIR/sign_update" "$STAGING_DIR/$DMG_NAME" -f "$KEY_FILE"
  rm -f "$KEY_FILE"
fi

if [ -n "$SPARKLE_BIN_DIR" ] && [ -x "$SPARKLE_BIN_DIR/generate_appcast" ]; then
  GENERATE_ARGS=(
    "$SPARKLE_BIN_DIR/generate_appcast"
    "$STAGING_DIR"
    --download-url-prefix "$DOWNLOAD_URL_PREFIX"
  )

  if [ -f "$UPDATES_DIR/appcast.xml" ]; then
    GENERATE_ARGS+=(--link "$UPDATES_DIR/appcast.xml")
  fi

  "${GENERATE_ARGS[@]}"
  cp "$STAGING_DIR/appcast.xml" "$UPDATES_DIR/appcast.xml"
else
  echo "Skipping appcast generation: Sparkle generate_appcast not available." >&2
fi

echo "Sparkle update assets written to $UPDATES_DIR/appcast.xml"
