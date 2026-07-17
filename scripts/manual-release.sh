#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_PATH=""
VERSION=""
TAG=""
SPARKLE_KEY=""
SPARKLE_BIN=""
PUBLISH=false
PUSH_APPCAST=false
REPO="libinmv/kannu"

usage() {
  cat <<EOF
Manual GitHub release helper for Kannu (after Xcode Archive → Developer ID export).

Prerequisites:
  1. Product → Archive (Release scheme) → Distribute App → Developer ID → export Kannu.app
  2. Sparkle 2.7 bin/ (sign_update, generate_appcast) — auto-downloaded if omitted
  3. Sparkle Ed25519 private key file matching SUPublicEDKey in Kannu/Info.plist

Usage:
  $0 \\
    --app <path-to-Kannu.app> \\
    --version <marketing-version> \\
    --tag <git-tag> \\
    --sparkle-key <path-to-eddsa-private.key> \\
    [--sparkle-bin <path-to-sparkle/bin>] \\
    [--publish] \\
    [--push-appcast]

Examples:
  $0 \\
    --app ~/Desktop/KannuRelease/Kannu.app \\
    --version 1.0.0 \\
    --tag v1.0.0 \\
    --sparkle-key ~/Keys/kannu-sparkle.key

  # Also create GitHub release and push Updates/appcast.xml:
  $0 ... --publish --push-appcast

Options:
  --publish       Run \`gh release create\` with the versioned DMG
  --push-appcast  Commit and push Updates/appcast.xml to origin main
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app)
      APP_PATH="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --sparkle-key)
      SPARKLE_KEY="$2"
      shift 2
      ;;
    --sparkle-bin)
      SPARKLE_BIN="$2"
      shift 2
      ;;
    --publish)
      PUBLISH=true
      shift
      ;;
    --push-appcast)
      PUSH_APPCAST=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$APP_PATH" ] || [ -z "$VERSION" ] || [ -z "$TAG" ] || [ -z "$SPARKLE_KEY" ]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 1
fi

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

if [ ! -f "$SPARKLE_KEY" ]; then
  echo "Sparkle private key not found: $SPARKLE_KEY" >&2
  exit 1
fi

if [[ "$TAG" != v* ]]; then
  echo "Tag should start with 'v' (e.g. v2.2.1), got: $TAG" >&2
  exit 1
fi

echo "Verifying Apple code signature on exported app..."
codesign -dv --verbose=2 "$APP_PATH" 2>&1 | head -5
if ! codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
  echo "::warning::codesign verify reported issues. Export with Developer ID from Xcode before releasing."
fi

if [ -z "$SPARKLE_BIN" ]; then
  SPARKLE_CACHE="$ROOT_DIR/build/sparkle-tools/bin"
  if [ -x "$SPARKLE_CACHE/sign_update" ] && [ -x "$SPARKLE_CACHE/generate_appcast" ]; then
    SPARKLE_BIN="$SPARKLE_CACHE"
  else
    echo "Downloading Sparkle 2.7.0 tools..."
    mkdir -p "$ROOT_DIR/build/sparkle-tools"
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/2.7.0/Sparkle-2.7.0.tar.xz" \
      -o "$ROOT_DIR/build/Sparkle-2.7.0.tar.xz"
    tar -xf "$ROOT_DIR/build/Sparkle-2.7.0.tar.xz" -C "$ROOT_DIR/build/sparkle-tools"
    SPARKLE_BIN="$ROOT_DIR/build/sparkle-tools/bin"
  fi
fi

if [ ! -x "$SPARKLE_BIN/sign_update" ] || [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "Sparkle tools not found in: $SPARKLE_BIN" >&2
  exit 1
fi

DMG_NAME="Kannu.${VERSION}.dmg"
DMG_PATH="$ROOT_DIR/build/${DMG_NAME}"
mkdir -p "$ROOT_DIR/build"

echo "Creating DMG: $DMG_PATH"
chmod +x "$ROOT_DIR/scripts/create-dmg.sh"
"$ROOT_DIR/scripts/create-dmg.sh" "$APP_PATH" "$DMG_PATH"

export SPARKLE_EDDSA_PRIVATE_KEY
SPARKLE_EDDSA_PRIVATE_KEY="$(cat "$SPARKLE_KEY")"

echo "Sparkle-signing DMG and updating Updates/appcast.xml..."
chmod +x "$ROOT_DIR/scripts/export-sparkle-update.sh"
"$ROOT_DIR/scripts/export-sparkle-update.sh" \
  "$DMG_PATH" \
  "$ROOT_DIR/Updates" \
  "https://github.com/${REPO}/releases/download/${TAG}/" \
  "$SPARKLE_BIN"

echo ""
echo "Release artifacts ready:"
echo "  DMG:     $DMG_PATH"
echo "  Appcast: $ROOT_DIR/Updates/appcast.xml"
echo ""

if $PUBLISH; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI not found; install from https://cli.github.com/" >&2
    exit 1
  fi
  echo "Creating GitHub release ${TAG}..."
  gh release create "$TAG" \
    "$DMG_PATH" \
    --repo "$REPO" \
    --title "Kannu ${VERSION}" \
    --generate-notes
  echo "Published: https://github.com/${REPO}/releases/tag/${TAG}"
else
  echo "Next: publish the release (upload $DMG_NAME), then push the appcast."
  echo "  gh release create ${TAG} \"${DMG_PATH}\" --repo ${REPO} --title \"Kannu ${VERSION}\" --generate-notes"
fi

if $PUSH_APPCAST; then
  if ! $PUBLISH; then
    echo "::warning::Publishing appcast before the GitHub release exists will produce broken download URLs until the release is live."
  fi
  git add Updates/appcast.xml
  if git diff --staged --quiet; then
    echo "Updates/appcast.xml unchanged."
  else
    git commit -m "Update appcast for ${TAG}"
    git push origin main
    echo "Pushed Updates/appcast.xml to main."
  fi
else
  echo "  git add Updates/appcast.xml && git commit -m \"Update appcast for ${TAG}\" && git push origin main"
fi
