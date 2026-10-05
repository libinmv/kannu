#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK_PATH="${ROOT_DIR}/homebrew/Casks/kannu.rb"
DEFAULT_TAP_REPO="libinmv/homebrew-kannu"

VERSION=""
DMG_PATH=""
PUSH_TAP=false

usage() {
  cat <<EOF
Rewrite version and sha256 in homebrew/Casks/kannu.rb from a release DMG.

Usage:
  $0 --version <marketing-version> --dmg <path-to-Kannu.VERSION.dmg> [--push-tap]

  --push-tap  Clone HOMEBREW_TAP_REPO (default ${DEFAULT_TAP_REPO}), copy
              homebrew/Casks and homebrew/lib, commit, and push.
              Needs git write access. CI: set HOMEBREW_TAP_TOKEN.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --dmg)
      DMG_PATH="$2"
      shift 2
      ;;
    --push-tap)
      PUSH_TAP=true
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

if [ -z "$VERSION" ] || [ -z "$DMG_PATH" ]; then
  echo "Missing --version or --dmg." >&2
  usage >&2
  exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

if [ ! -f "$CASK_PATH" ]; then
  echo "Cask not found: $CASK_PATH" >&2
  exit 1
fi

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

python3 - "$CASK_PATH" "$VERSION" "$SHA256" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
version, sha256 = sys.argv[2], sys.argv[3]
text = path.read_text(encoding="utf-8")
text, n_ver = re.subn(
    r'^  version "[^"]+"$',
    f'  version "{version}"',
    text,
    count=1,
    flags=re.MULTILINE,
)
text, n_sha = re.subn(
    r'^  sha256 .+$',
    f'  sha256 "{sha256}"',
    text,
    count=1,
    flags=re.MULTILINE,
)
if n_ver != 1 or n_sha != 1:
    sys.exit(
        f"Expected to rewrite one version line and one sha256 line "
        f"(version={n_ver}, sha256={n_sha}) in {path}"
    )
path.write_text(text, encoding="utf-8")
PY

echo "Updated ${CASK_PATH}"
echo "  version ${VERSION}"
echo "  sha256  ${SHA256}"

if ! $PUSH_TAP; then
  echo "Tap not pushed. Re-run with --push-tap once libinmv/homebrew-kannu exists."
  exit 0
fi

TAP_REPO="${HOMEBREW_TAP_REPO:-$DEFAULT_TAP_REPO}"
TOKEN="${HOMEBREW_TAP_TOKEN:-}"

TAP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TAP_DIR"
}
trap cleanup EXIT

if [ -n "$TOKEN" ]; then
  TAP_URL="https://x-access-token:${TOKEN}@github.com/${TAP_REPO}.git"
else
  TAP_URL="git@github.com:${TAP_REPO}.git"
fi

echo "Cloning ${TAP_REPO}..."
if git clone --depth 1 "$TAP_URL" "$TAP_DIR/tap"; then
  :
else
  echo "Clone failed (empty repo is expected on first push); initializing ${TAP_REPO}."
  mkdir -p "$TAP_DIR/tap"
  git -C "$TAP_DIR/tap" init -b main
  git -C "$TAP_DIR/tap" remote add origin "$TAP_URL"
fi

mkdir -p "$TAP_DIR/tap/Casks" "$TAP_DIR/tap/lib"
cp "$ROOT_DIR/homebrew/Casks/kannu.rb" "$TAP_DIR/tap/Casks/kannu.rb"
cp "$ROOT_DIR/homebrew/lib/github_private_release_download_strategy.rb" \
  "$TAP_DIR/tap/lib/github_private_release_download_strategy.rb"
cp "$ROOT_DIR/homebrew/README.md" "$TAP_DIR/tap/README.md"

git -C "$TAP_DIR/tap" config user.name "github-actions[bot]"
git -C "$TAP_DIR/tap" config user.email "github-actions[bot]@users.noreply.github.com"
git -C "$TAP_DIR/tap" add Casks/kannu.rb lib/github_private_release_download_strategy.rb README.md

if git -C "$TAP_DIR/tap" diff --staged --quiet; then
  echo "Tap ${TAP_REPO} already matches this cask."
  exit 0
fi

git -C "$TAP_DIR/tap" commit -m "kannu ${VERSION}"
if git -C "$TAP_DIR/tap" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  git -C "$TAP_DIR/tap" push origin HEAD
else
  git -C "$TAP_DIR/tap" push -u origin HEAD
fi
echo "Pushed cask ${VERSION} to ${TAP_REPO}."
