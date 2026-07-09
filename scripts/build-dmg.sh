#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/DynamicIsland.xcodeproj"
SCHEME="DynamicIsland"
CONFIGURATION="Release"
DERIVED_DATA="$ROOT_DIR/build"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Kannu.app"
DMG_PATH="$ROOT_DIR/build/Kannu.dmg"
ENTITLEMENTS_SRC="$ROOT_DIR/DynamicIsland/DynamicIsland.entitlements"

SKIP_BUILD=false
OPEN_DMG=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build Kannu Release and package build/Kannu.dmg (ad-hoc signed).

Options:
  --skip-build  Package an existing Release app without rebuilding
  --open        Open the DMG in Finder when done (default)
  --no-open     Do not open the DMG after build
  -h, --help    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --open)
      OPEN_DMG=true
      shift
      ;;
    --no-open)
      OPEN_DMG=false
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: DMG builds require macOS" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found; install Xcode" >&2
  exit 1
fi

TEMP_ENTITLEMENTS=""
cleanup() {
  if [[ -n "$TEMP_ENTITLEMENTS" && -f "$TEMP_ENTITLEMENTS" ]]; then
    rm -f "$TEMP_ENTITLEMENTS"
  fi
}
trap cleanup EXIT

prepare_entitlements() {
  if [[ ! -f "$ENTITLEMENTS_SRC" ]]; then
    echo "error: entitlements not found at $ENTITLEMENTS_SRC" >&2
    exit 1
  fi

  TEMP_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/kannu-entitlements.XXXXXX")"
  cp "$ENTITLEMENTS_SRC" "$TEMP_ENTITLEMENTS"

  # Ad-hoc builds fail when mach-services is present (amfid kills the app).
  if ! plutil_out=$(plutil -remove com.apple.security.mach-services "$TEMP_ENTITLEMENTS" 2>&1); then
    if printf '%s' "$plutil_out" | grep -q "No value to remove"; then
      : # already absent
    else
      echo "error: plutil failed to modify entitlements: $plutil_out" >&2
      exit 1
    fi
  fi
}

build_app() {
  echo "==> Building $SCHEME ($CONFIGURATION)..."
  prepare_entitlements

  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES \
    CODE_SIGN_ENTITLEMENTS="$TEMP_ENTITLEMENTS"
}

package_dmg() {
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app not found at $APP_PATH" >&2
    echo "Run without --skip-build to build first." >&2
    exit 1
  fi

  echo "==> Creating DMG..."
  "$ROOT_DIR/scripts/create-dmg.sh" "$APP_PATH" "$DMG_PATH"
}

if [[ "$SKIP_BUILD" == false ]]; then
  build_app
else
  echo "==> Skipping build (--skip-build)"
fi

package_dmg

echo ""
echo "Done."
echo "  App: $APP_PATH"
echo "  DMG: $DMG_PATH"

if [[ "$OPEN_DMG" == true ]]; then
  open "$DMG_PATH"
fi
