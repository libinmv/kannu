# കണ്ണ് (Kannu)

<p align="center">
  <img src=".github/assets/eyes.jpeg" alt="Kannu logo" width="160">
</p>

**Kannu** is a macOS notch utility focused on **AI agent status** in the MacBook notch. It shows a traffic-light indicator while Cursor, VS Code Copilot, or Codex agents run, with optional custom notch backgrounds and mobile push notifications.

This project is licensed under GPL v3. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for upstream attribution.

## Highlights

- **Agent status traffic light** — yellow (thinking), green (executing), red (stopped), fed by editor hooks and transcript polling.
- **Custom notch skins** — upload a background image clipped to the notch shape, with optional dark scrim for readability.
- **Mobile notifications (optional)** — push agent state changes to iPhone, Apple Watch, or Android via ntfy, Pushover, or a custom webhook.
- Media controls, live activities, lock screen widgets, stats, timers, clipboard, and shelf.
- **Keyboard shortcuts off by default** — enable globally in Settings → Shortcuts when you want hotkeys.

Calendar, terminal, and color picker features from the upstream notch lineage are removed in this fork.

## Requirements

- macOS 14.0 or later (optimised for macOS 15+).
- MacBook with a notch, or a non-notch Mac using floating Dynamic Island pill mode.
- Xcode 15+ to build from source.
- Permissions as needed: Accessibility, Screen Recording, Music.

## Build from Source

1. Open `DynamicIsland.xcodeproj` in Xcode.
2. Select the **Kannu** scheme and your Mac as the run destination.
3. Build and run (⌘R).

Application support data is stored under `~/Library/Application Support/Kannu/`. Agent status hooks write to `~/.kannu/agent-status/`.

## Create a DMG

From the repo root, build a Release app and package it:

```bash
xcodebuild build \
  -project DynamicIsland.xcodeproj \
  -scheme DynamicIsland \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build

chmod +x scripts/create-dmg.sh
./scripts/create-dmg.sh
```

This writes `build/Kannu.dmg` with `Kannu.app` and an Applications shortcut.

## Publish on GitHub

1. Commit and push your changes (including `.github/assets/` branding files).
2. Tag a release, for example `git tag v2.2.0 && git push origin v2.2.0`.
3. The [Release workflow](.github/workflows/release.yml) builds the DMG and attaches it to the GitHub Release for that tag.

For wider distribution outside GitHub, sign the app with a Developer ID certificate before creating the DMG so macOS Gatekeeper accepts it. The CI workflow produces an unsigned ad-hoc build suitable for testing and source builds.

## Quick Start

1. Launch Kannu and complete onboarding.
2. Open **Settings → Agent Status** and install editor hooks for Cursor (recommended).
3. Run an AI agent in Cursor — the notch shows the traffic-light status when collapsed.
4. Optionally upload a notch skin under **Settings → Appearance → Notch skin**.

## Mobile Notifications Setup

1. Open **Settings → Agent Status → Mobile Notifications**.
2. Enable mobile notifications and choose a provider:
   - **ntfy** — create a topic at [ntfy.sh](https://ntfy.sh) or self-host. Install the ntfy app on iPhone or Android and subscribe to your topic.
   - **Pushover** — use your user key and app token from [pushover.net](https://pushover.net).
   - **Webhook** — POST JSON `{ "state": "thinking", "title": "...", "body": "...", "timestamp": "..." }` to your URL.
3. Tap **Send test notification** to verify delivery.

Notifications are debounced (~2 seconds) and skip the inactive state unless you opt in. Apple Watch mirrors iPhone alerts when mirroring is enabled in Watch settings.

**Privacy:** Agent status stays on your Mac unless you enable outbound notifications. Public ntfy topics can be read by anyone unless you self-host with authentication.

## Phase 2 — Windows and Linux

See [docs/PHASE2.md](docs/PHASE2.md) for the planned shared `kannu-core` watcher and Tauri-based shells for Windows 11 and Linux.

## License

GPL v3 — see [LICENSE](LICENSE).

## Acknowledgments

Kannu builds on [Boring.Notch](https://github.com/TheBoredTeam/boring.notch) and other open-source macOS notch projects listed in upstream documentation.
