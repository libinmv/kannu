# Homebrew private tap

Kannu is a GUI Mac app, so Homebrew installs it as a **cask**, not a formula. Distribution uses a **private tap** (a GitHub repo Homebrew clones) so the cask never has to live on `homebrew/cask`.

Two GitHub repositories:

| Repo | Visibility | Role |
|---|---|---|
| `libinmv/kannu` | your choice | App source, CI, GitHub Releases (`Kannu.<version>.dmg`) |
| `libinmv/homebrew-kannu` | **private** | The tap: `Casks/kannu.rb` |

Homebrew maps `brew tap libinmv/kannu` to a repo named **`homebrew-kannu`**. Do not name the tap repo `kannu-tap` or `homebrew-kannu-tap`; `brew tap libinmv/kannu` would then miss it.

The files under [`homebrew/`](../homebrew/) in this repository are that tap tree. Keep them here as the canonical copy; the private repo is what `brew tap` clones.

## One-time: create the tap on GitHub

1. Create a **private** empty repository `https://github.com/libinmv/homebrew-kannu` (no README, no license — this tree already has those files).
2. From a clone of Kannu:

```bash
cd homebrew
git init
git add Casks lib README.md
git commit -m "Add Kannu cask for the private tap."
git branch -M main
git remote add origin git@github.com:libinmv/homebrew-kannu.git
git push -u origin main
```

3. Confirm the tap layout on GitHub is exactly:

```
Casks/kannu.rb
lib/github_private_release_download_strategy.rb
README.md
```

`Casks/` must sit at the **root** of `homebrew-kannu`, not nested as `homebrew/Casks`.

## Install from the private tap

```bash
brew tap libinmv/kannu git@github.com:libinmv/homebrew-kannu.git
brew install --cask kannu
```

If the **app** GitHub Releases are public, that is all. Sparkle inside the app still offers in-app updates; `brew upgrade --cask kannu` tracks the cask `version` field.

### Private GitHub Releases

Default `url` in `Casks/kannu.rb` is a normal browser download. That 404s on a private app repo.

1. Create a PAT with read access to `libinmv/kannu` release assets (`repo` on a classic token).
2. Export it for Homebrew:

```bash
export HOMEBREW_GITHUB_API_TOKEN=ghp_...
```

3. In `Casks/kannu.rb`, uncomment `require_relative` and the `url` line that sets `using: GitHubPrivateReleaseDownloadStrategy`. Comment out the public `url` line.
4. Commit that change in this repo and push the tap.

## Per-release: bump version and SHA-256

After a notarized `Kannu.<version>.dmg` exists:

```bash
./scripts/update-homebrew-cask.sh \
  --version 1.3.3 \
  --dmg build/Kannu.1.3.3.dmg
```

That rewrites `version` and `sha256` in `homebrew/Casks/kannu.rb`.

Push the tap (needs write access to `homebrew-kannu`):

```bash
./scripts/update-homebrew-cask.sh \
  --version 1.3.3 \
  --dmg build/Kannu.1.3.3.dmg \
  --push-tap
```

`--push-tap` clones `libinmv/homebrew-kannu`, copies `homebrew/Casks` and `homebrew/lib`, commits, and pushes. Override the tap with `HOMEBREW_TAP_REPO=owner/homebrew-kannu`. For HTTPS from CI, set `HOMEBREW_TAP_TOKEN` to a PAT that can push that repo.

Until the first real DMG checksum is written, the cask uses `sha256 :no_check` so a tap bootstrap does not invent a digest.

## CI

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs the same script after the GitHub Release is published.

Optional secret on `libinmv/kannu`:

| Secret | Purpose |
|---|---|
| `HOMEBREW_TAP_TOKEN` | PAT with **contents: write** on `libinmv/homebrew-kannu` |

If the secret is missing, CI still updates `homebrew/Casks/kannu.rb` on `main` in this repo and skips the tap push, so the first tap repo can be created later and filled from `homebrew/`.

## Manual release

[`scripts/manual-release.sh`](../scripts/manual-release.sh) prints the `update-homebrew-cask.sh` command after it builds the DMG. Run that (and `--push-tap` if the tap exists) once the GitHub Release is up, so the cask URL resolves.

## Rename owner or tap

If GitHub user/org is not `libinmv`, replace `libinmv` in:

- `homebrew/Casks/kannu.rb` (`url`, `homepage`)
- `homebrew/README.md`
- `scripts/update-homebrew-cask.sh` (`DEFAULT_TAP_REPO`)
- this file

Keep the tap repository name `homebrew-kannu` so the tap token stays `OWNER/kannu`.
