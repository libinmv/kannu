# Homebrew tap for Kannu

This directory is the **tap tree**. Copy it to a private GitHub repository named `homebrew-kannu` (the `homebrew-` prefix is required so `brew tap OWNER/kannu` resolves).

Install (after the tap repo exists):

```bash
brew tap libinmv/kannu git@github.com:libinmv/homebrew-kannu.git
brew install --cask kannu
```

HTTPS instead of SSH:

```bash
brew tap libinmv/kannu https://github.com/libinmv/homebrew-kannu.git
brew install --cask kannu
```

Private clone needs GitHub auth (SSH key, `gh auth`, or `HOMEBREW_GITHUB_API_TOKEN`).

Upgrade:

```bash
brew update
brew upgrade --cask kannu
```

Uninstall:

```bash
brew uninstall --cask kannu
```

Kannu also updates itself via Sparkle when a GitHub Release is published. Homebrew still tracks the cask version for `brew upgrade`.

If GitHub Releases on the app repo are private, set `HOMEBREW_GITHUB_API_TOKEN` and enable `GitHubPrivateReleaseDownloadStrategy` in `Casks/kannu.rb` (see [docs/HOMEBREW.md](../docs/HOMEBREW.md) in the Kannu source repo).

Maintainer setup lives in the Kannu repo: [docs/HOMEBREW.md](../docs/HOMEBREW.md).
