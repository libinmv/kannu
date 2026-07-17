#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <path-to-Kannu.app> <output-directory> <download-url-prefix> [sparkle-bin-dir]" >&2
  exit 1
fi

APP_PATH="$1"
OUTPUT_DIR="$2"
DOWNLOAD_URL_PREFIX="$3"
SPARKLE_BIN_DIR="${4:-}"

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

ZIP_PATH="$OUTPUT_DIR/Kannu.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]; then
  if [ -z "$SPARKLE_BIN_DIR" ]; then
    echo "Sparkle bin directory is required when SPARKLE_EDDSA_PRIVATE_KEY is set." >&2
    exit 1
  fi

  KEY_FILE="$(mktemp)"
  cleanup() {
    rm -f "$KEY_FILE"
  }
  trap cleanup EXIT

  printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY" > "$KEY_FILE"
  "$SPARKLE_BIN_DIR/sign_update" "$ZIP_PATH" -f "$KEY_FILE"
fi

if [ -n "$SPARKLE_BIN_DIR" ] && [ -x "$SPARKLE_BIN_DIR/generate_appcast" ]; then
  "$SPARKLE_BIN_DIR/generate_appcast" "$OUTPUT_DIR" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX"
else
  echo "Skipping appcast generation: Sparkle generate_appcast not available." >&2
fi

echo "Sparkle update assets written to $OUTPUT_DIR"
