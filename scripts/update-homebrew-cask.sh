#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <version> <sha256-or-dmg-path> [tap-repo-url]" >&2
  exit 1
fi

VERSION="$1"
SHA256_OR_DMG="$2"
TAP_REPO_URL="${3:-https://github.com/libinmv/homebrew-kannu.git}"

if [ -f "$SHA256_OR_DMG" ]; then
  SHA256="$(shasum -a 256 "$SHA256_OR_DMG" | awk '{print $1}')"
else
  SHA256="$SHA256_OR_DMG"
fi

if [ -z "${HOMEBREW_TAP_TOKEN:-}" ]; then
  echo "HOMEBREW_TAP_TOKEN is not set; skipping Homebrew tap update."
  exit 0
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

CLONE_URL="${TAP_REPO_URL/https:\/\/github.com/https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com}"

git clone --depth 1 "$CLONE_URL" "$WORK_DIR/tap"
mkdir -p "$WORK_DIR/tap/Casks"

cat > "$WORK_DIR/tap/Casks/kannu.rb" <<RUBY
cask "kannu" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/libinmv/kannu/releases/download/v\#{version}/Kannu.\#{version}.dmg"
  name "Kannu"
  desc "macOS notch utility for AI agent status"
  homepage "https://github.com/libinmv/kannu"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Kannu.app"

  auto_updates true

  zap trash: [
    "~/Library/Application Support/Kannu",
    "~/.kannu",
  ]
end
RUBY

pushd "$WORK_DIR/tap" > /dev/null
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

git add Casks/kannu.rb
if git diff --staged --quiet; then
  echo "Homebrew cask already up to date for ${VERSION}."
  exit 0
fi

git commit -m "Update kannu cask to ${VERSION}"
git push origin HEAD
popd > /dev/null

echo "Updated homebrew-kannu tap to ${VERSION} (${SHA256})."
