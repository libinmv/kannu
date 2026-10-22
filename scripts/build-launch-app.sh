#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Kannu.xcodeproj"
SCHEME="Kannu"
CONFIGURATION="Release"
DERIVED_DATA="$ROOT_DIR/build"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Kannu.app"
ENTITLEMENTS_SRC="$ROOT_DIR/Kannu/Kannu.entitlements"

SKIP_BUILD=false
OPEN_APP=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build Kannu Release and launch the local app.

Options:
  --skip-build  Launch an existing Release app without rebuilding
  --no-open     Build only; do not launch the app
  --open        Launch the app when done (default)
  -h, --help    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --no-open)
      OPEN_APP=false
      shift
      ;;
    --open)
      OPEN_APP=true
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
  echo "error: local app launch requires macOS" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found; install Xcode" >&2
  exit 1
fi

build_app() {
  echo "==> Building $SCHEME ($CONFIGURATION)..."

  # Signs Kannu/Kannu.entitlements as it is, disable-library-validation included. An ad-hoc
  # signature has no Team ID, so with library validation on, dyld refuses the embedded Lottie and
  # Sparkle frameworks ("mapping process and mapped file (non-platform) have different Team IDs")
  # and the app never starts.
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
    CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS_SRC"
}

if [[ "$SKIP_BUILD" == false ]]; then
  build_app
else
  echo "==> Skipping build (--skip-build)"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found at $APP_PATH" >&2
  echo "Run without --skip-build to build first." >&2
  exit 1
fi

echo ""
echo "Done."
echo "  App: $APP_PATH"

if [[ "$OPEN_APP" == true ]]; then
  if ! open "$APP_PATH"; then
    echo "warning: failed to launch $APP_PATH via open; launch it manually from Finder." >&2
  fi
fi
