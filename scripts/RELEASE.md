# Kannu Release Guide

Ship Kannu via **automated CI** (recommended) or **manual Xcode** export.

## Automated CI release (recommended)

Triggered only by pushing a `v*` tag. The workflow archives with Developer ID, notarizes the DMG, Sparkle-signs the appcast, publishes to GitHub Releases, and commits [`Updates/appcast.xml`](../Updates/appcast.xml).

### One-time: GitHub secrets

Add at **Settings → Secrets and variables → Actions** on `libinmv/kannu`:

| Secret | Description |
|--------|-------------|
| `APPLE_CERTIFICATE` | Base64-encoded **Developer ID Application** `.p12` (must include private key) |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` export |
| `KEYCHAIN_PASSWORD` | Random string for the CI keychain (`openssl rand -base64 32`) |
| `APPLE_TEAM_ID` | 10-character team ID (Release: `S2WWHQQH2V`) |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_NOTARIZATION_PASSWORD` | App-specific password from [appleid.apple.com](https://appleid.apple.com) |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Ed25519 private seed matching `SUPublicEDKey` in `Kannu/Info.plist` |

Example (run locally after exporting your `.p12`):

**Export the correct certificate from Keychain Access:**

1. Open **Keychain Access** → **login** keychain → **My Certificates**
2. Find **Developer ID Application: Your Name (S2WWHQQH2V)** — not "Apple Development"
3. Expand it; a **private key** must appear nested underneath
4. Select the certificate (not just the key) → **File → Export Items** → `.p12`
5. Set a password (this becomes `APPLE_CERTIFICATE_PASSWORD`)

Verify locally before uploading:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

#### Add secrets in GitHub (no CLI required)

1. Open **https://github.com/libinmv/kannu/settings/secrets/actions**
2. For each secret: **New repository secret** (or **Update** if it already exists)
3. **Name** must match the table exactly; paste the **Value**; click **Add secret**

| Secret | How to get the value |
|--------|----------------------|
| `APPLE_CERTIFICATE` | Terminal: `base64 -i ~/path/to/cert.p12 \| pbcopy` → paste entire output (one long line is fine) |
| `APPLE_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Terminal: `openssl rand -base64 32` → copy output |
| `APPLE_TEAM_ID` | `S2WWHQQH2V` |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_NOTARIZATION_PASSWORD` | App-specific password from [appleid.apple.com](https://appleid.apple.com) |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Open your Sparkle private key file in a text editor → copy all contents |

To **update** a secret after a bad upload: open the secret on that page → **Update** → paste the new value.

<details>
<summary>Optional: GitHub CLI (<code>gh</code>)</summary>

```bash
gh secret set APPLE_CERTIFICATE --repo libinmv/kannu < <(base64 -i ~/path/to/cert.p12)
gh secret set APPLE_CERTIFICATE_PASSWORD --repo libinmv/kannu
gh secret set KEYCHAIN_PASSWORD --repo libinmv/kannu
gh secret set APPLE_TEAM_ID --repo libinmv/kannu --body "S2WWHQQH2V"
gh secret set APPLE_ID --repo libinmv/kannu
gh secret set APPLE_NOTARIZATION_PASSWORD --repo libinmv/kannu
gh secret set SPARKLE_EDDSA_PRIVATE_KEY --repo libinmv/kannu < ~/path/to/eddsa_private.key
```

</details>

### Release day

1. Bump **Version** and **Build** in Xcode or `Kannu.xcodeproj/project.pbxproj`
2. Commit and push to `main`
3. Tag and push:

```bash
git tag v1.0.0
git push origin v1.0.0
```

4. Watch **Actions → Release**
5. Verify the GitHub Release contains `Kannu.<version>.dmg` and `Updates/appcast.xml` updated on `main`

### Test with a pre-release tag

```bash
git tag v1.0.0-test.1
git push origin v1.0.0-test.1
```

Delete the test release afterward if desired.

---

## Manual GitHub release (fallback)

Build and ship from Xcode when CI is unavailable.

### Quick start

1. **Bump version** in Xcode (target Kannu → General): increase **Version** and **Build**.
2. **Archive**: Product → Archive (Release scheme) → Distribute App → **Developer ID** → export `Kannu.app`.
3. **Run the release script** from repo root:

```bash
chmod +x scripts/manual-release.sh

./scripts/manual-release.sh \
  --app ~/Desktop/KannuRelease/Kannu.app \
  --version 1.0.0 \
  --tag v1.0.0 \
  --sparkle-key ~/path/to/eddsa_private.key \
  --publish \
  --push-appcast
```

Without `--publish` / `--push-appcast`, the script only builds `build/Kannu.<version>.dmg` and updates `Updates/appcast.xml`, then prints the commands to run manually.

### What the manual script does

1. Verifies the exported app is code-signed
2. Creates `build/Kannu.<version>.dmg` via [`create-dmg.sh`](create-dmg.sh)
3. Sparkle-signs the DMG and merges [`Updates/appcast.xml`](../Updates/appcast.xml) via [`export-sparkle-update.sh`](export-sparkle-update.sh)
4. Optionally creates a GitHub Release via `gh` (omit `--publish` to upload the DMG manually on github.com → Releases → Draft a new release)

Manual releases do **not** notarize automatically; use CI for notarized builds.

---

## Verify signing

```bash
codesign -dv --verbose=4 /path/to/Kannu.app
spctl -a -vv /path/to/Kannu.app
```

## Verify auto-update

1. Install an older build to `/Applications`
2. Launch Kannu → **Check for Updates…**
3. Optional logs: `log stream --predicate 'process CONTAINS "Kannu" OR subsystem CONTAINS "sparkle"' --level debug`

## Workflow reference

CI pipeline: [`.github/workflows/release.yml`](../.github/workflows/release.yml)

Scripts:

- [`notarize-dmg.sh`](notarize-dmg.sh) — `notarytool submit` + staple
- [`export-sparkle-update.sh`](export-sparkle-update.sh) — Sparkle-sign DMG + appcast
- [`manual-release.sh`](manual-release.sh) — local release helper
