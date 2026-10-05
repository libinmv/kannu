# frozen_string_literal: true

# Canonical cask for the private tap `libinmv/kannu` (GitHub: libinmv/homebrew-kannu).
# `scripts/update-homebrew-cask.sh` rewrites `version` and `sha256` on each release.
#
# If GitHub Releases on libinmv/kannu are private, uncomment the require and the
# `using:` keyword on `url`. Public releases leave both commented.

# require_relative "../lib/github_private_release_download_strategy"

cask "kannu" do
  version "1.3.3"
  sha256 :no_check

  url "https://github.com/libinmv/kannu/releases/download/v#{version}/Kannu.#{version}.dmg"
  # url "https://github.com/libinmv/kannu/releases/download/v#{version}/Kannu.#{version}.dmg",
  #     using: GitHubPrivateReleaseDownloadStrategy
  name "Kannu"
  desc "MacBook notch utility for watching AI coding agents"
  homepage "https://github.com/libinmv/kannu"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Kannu.app"

  uninstall quit: "com.kannu.app"

  zap trash: [
    "~/.kannu",
    "~/Library/Application Support/Kannu",
    "~/Library/Caches/com.kannu.app",
    "~/Library/HTTPStorages/com.kannu.app",
    "~/Library/Preferences/com.kannu.app.plist",
  ]
end
