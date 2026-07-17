# Manual GitHub Release

Build and ship Kannu from Xcode with your local signing identity, then publish a DMG to GitHub Releases and update the Sparkle appcast (Atoll-style).

## Quick start

1. **Bump version** in Xcode (target Kannu → General): increase **Version** and **Build**.
2. **Archive**: Product → Archive (Release scheme) → Distribute App → **Developer ID** → export `Kannu.app`.
3. **Run the release script** from repo root:

```bash
chmod +x scripts/manual-release.sh

./scripts/manual-release.sh \
  --app ~/Desktop/KannuRelease/Kannu.app \
  --version 2.2.1 \
  --tag v2.2.1 \
  --sparkle-key ~/path/to/eddsa_private.key \
  --publish \
  --push-appcast
```

Without `--publish` / `--push-appcast`, the script only builds `build/Kannu.<version>.dmg` and updates `Updates/appcast.xml`, then prints the commands to run manually.

## What the script does

1. Verifies the exported app is code-signed
2. Creates `build/Kannu.<version>.dmg` via [`create-dmg.sh`](create-dmg.sh)
3. Sparkle-signs the DMG and merges [`Updates/appcast.xml`](../Updates/appcast.xml) via [`export-sparkle-update.sh`](export-sparkle-update.sh)
4. Optionally runs `gh release create` and pushes the appcast to `main`

## Prerequisites

| Item | Notes |
|------|--------|
| **Developer ID in Xcode** | Release target `com.kannu.app` — use Archive, not Debug |
| **Sparkle private key** | Must match `SUPublicEDKey` in `Kannu/Info.plist` |
| **Sparkle tools** | Downloaded automatically to `build/sparkle-tools/` if missing |
| **`gh` CLI** | Required only for `--publish` |

## Verify signing

```bash
codesign -dv --verbose=4 /path/to/Kannu.app
spctl -a -vv /path/to/Kannu.app
```

## Verify auto-update

1. Install an older build to `/Applications`
2. Launch Kannu → **Check for Updates…**
3. Optional logs: `log stream --predicate 'process CONTAINS "Kannu" OR subsystem CONTAINS "sparkle"' --level debug`

## CI releases

The optional [`.github/workflows/release.yml`](../.github/workflows/release.yml) automates the same flow in GitHub Actions. Manual releases do not require those secrets.
