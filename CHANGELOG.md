# Changelog

Each commit must add one new entry under `## [Unreleased]` before committing.

## [Unreleased]

### 2026-07-10 - Upgrade GitHub Actions to Node.js 24
- **Developer label:** Upgrade GitHub Actions to Node.js 24
- **Agent label:** Node 24 CI Actions upgrade
- **Changes:**
  - Bumped `actions/checkout` from v5 to v6 in `.github/workflows/ci.yml`, `.github/workflows/release.yml`, and `.github/workflows/update-pricing.yml`.
  - Bumped `actions/upload-artifact` from v5 to v7 in `.github/workflows/ci.yml` and `.github/workflows/release.yml` to eliminate Node.js 20 deprecation warnings on GitHub-hosted runners.

### 2026-07-10 - Atoll/Ebullioscopic Cleanup — Scope and Implementation Plan
- **Developer label:** Atoll/Ebullioscopic Cleanup — Scope and Implementation Plan
- **Agent label:** Implement user-facing Ebullioscopic cleanup scope
- **Changes:**
  - Updated `Kannu/components/Onboarding/WelcomeView.swift` to open privacy policy at `https://kannu.app/legal/privacy-policy/`.
  - Updated `Kannu/managers/LLMUsage/ModelPricingManager.swift` remote pricing source to `https://raw.githubusercontent.com/libinmv/kannu/main/Kannu/managers/LLMUsage/pricing.json`.
  - Removed empty asset directory `Kannu/Assets.xcassets/ebullioscopic.imageset`.
  - Removed stale root-level `Localizable.xcstrings`; retained active localization catalog at `Kannu/Localizable.xcstrings`.

### 2026-07-10 - Extension RPC dual namespace migration (Phase 1)
- **Developer label:** Atoll/Ebullioscopic Cleanup Plan (Two Tracks)
- **Agent label:** Track 2 extension RPC dual namespace support
- **Changes:**
  - Added `Kannu/services/Extensions/ExtensionRPCNamespace.swift` to canonicalize `atoll.*` and `kannu.*` RPC method names and track namespace usage counters.
  - Updated `ExtensionRPCService.swift` to route both namespaces to existing handlers without breaking legacy extension clients.
  - Updated `ExtensionRPCServer.swift` to accept `kannu.requestAuthorization` for identity binding and dual-emit `atoll.*`/`kannu.*` notifications during migration.
  - Extended `docs/ATOLL_TO_KANNU_MIGRATION_PLAN.md` with Phase 1 implementation status and client migration examples.

### 2026-07-10 - Atoll/Ebullioscopic Cleanup Plan (Two Tracks)
- **Developer label:** Atoll/Ebullioscopic Cleanup Plan (Two Tracks)
- **Agent label:** Track 1 branding cleanup and Track 2 migration plan
- **Changes:**
  - Removed stale Ebullioscopic onboarding leftovers by deleting the unused `ebullioscopic.imageset` and stale `Made with ❤️ by Ebullioscopic` localization key.
  - Rebranded `logo.imageset` from `Atoll.png` to `KannuIcon-1024.png` and updated asset metadata to keep the `logo` image key stable.
  - Updated internal sharing notification namespace to `com.kannu.sharingDidFinish` and added TODO markers for migrating privacy-policy/pricing URLs to Kannu-owned hosting.
  - Added a separate phased migration strategy document for non-breaking `atoll.*` to `kannu.*` extension API transition.

### 2026-07-10 - Update onboarding branding to Kannu
- **Developer label:** Update onboarding branding to Kannu
- **Agent label:** Replace welcome screen Atoll icon and remove Ebullioscopic footer
- **Changes:**
  - Replaced `Kannu/Assets.xcassets/logo2.imageset` source image from `Atoll_1024.png` to `KannuIcon-1024.png` and updated its `Contents.json` mapping.
  - Removed the bottom `Image("ebullioscopic")` branding overlay from `Kannu/components/Onboarding/WelcomeView.swift` so first-launch onboarding no longer shows Ebullioscopic branding.

### 2026-07-09 - Round-2 Extension IPC Hardening
- **Developer label:** Round-2 Extension IPC Hardening
- **Agent label:** Round-2 extension IPC hardening
- **Changes:**
  - Updated `Kannu/services/Extensions/ExtensionXPCService.swift` so pending extensions are no longer auto-authorized on XPC requestAuthorization.
  - Hardened `Kannu/services/Extensions/ExtensionRPCServer.swift` with XPC-backed identity attestation and one active RPC session per bundle identifier.
  - Added `hasActiveConnection(bundleIdentifier:)` in `Kannu/services/Extensions/ExtensionXPCServiceHost.swift` for RPC identity verification.
  - Removed direct `paths` ingestion in `Kannu/services/Extensions/ExtensionRPCService.swift`; file adds now require `files` (base64) or `text` payloads.
  - Changed extension diagnostics default to off in `Kannu/models/Constants.swift` and replaced raw descriptor payload logging with size-only diagnostics in RPC handlers.

### 2026-07-09 - Rename DynamicIsland internals to Kannu
- **Developer label:** Rename DynamicIsland internals to Kannu
- **Agent label:** Scaffolding rename DynamicIsland -> Kannu
- **Changes:**
  - Renamed project scaffolding from `DynamicIsland` to `Kannu` across source folders, Xcode project/scheme, and UI test target naming.
  - Updated core scaffolding symbols (for example `KannuViewModel`, `KannuViewCoordinator`, `KannuApp`) while keeping Dynamic Island display-mode identifiers intact.
  - Repointed build scripts, CI workflows, and contributor docs to `Kannu.xcodeproj` and scheme `Kannu`.
  - Updated app-referencing copy to Kannu in onboarding/privacy and screenshot-hiding settings, while preserving Dynamic Island mode wording.

### 2026-07-09 - Calendar removal and runtime permissions docs
- **Developer label:** Calendar removal and runtime permissions docs
- **Agent label:** Calendar cleanup, branding, and permissions documentation
- **Changes:**
  - Removed remaining calendar types, defaults, lock-screen row ordering, and stale localization strings.
  - Simplified lock-screen weather widget to weather and focus rows only.
  - Updated Full Disk Access prompt copy from Dynamic Island to Kannu branding.
  - Documented camera monitor as privacy-indicator-only (no capture or frame access).
  - Added README runtime-permissions section mapping features to macOS TCC prompts.
  - Updated contributor docs to target `development` for pull requests.

### 2026-07-09 - Feature label and changelog workflow (mundackan)
- **Developer label:** Feature label and changelog workflow
- **Agent label:** Feature changelog rule and commit enforcement
- **Changes:**
  - Added always-on Cursor rule requiring developer and agent feature labels.
  - Added `CHANGELOG.md` with per-commit entry format and change bullets.
  - Added `.githooks/pre-commit` validation for staged changelog entries.
  - Added `scripts/install-git-hooks.sh` and documented setup in `CONTRIBUTING.md`.
  - Removed Spotify/Apple Music like-heart feature integration from media controllers and UI.
  - Improved agent status display with project names and execution timing.
  - Polished notch foreground theming, settings color picker flow, and OSD cleanup behavior.
  - Added local build and DMG packaging scripts plus README build instructions.

### 2026-07-09 - Remove music like feature rollout
- **Developer label:** Remove music like feature rollout
- **Agent label:** Revert like/heart feature integration
- **Changes:**
  - Removed track-like capability fields and methods from the media controller protocol.
  - Removed Apple Music loved-track state and toggle flow.
  - Removed Spotify liked-track state flow and deleted `SpotifyLibraryService`.
  - Removed `.like` control from music slot configuration and music control button model.
  - Removed heart/like UI controls from notch and lock-screen music views.

### YYYY-MM-DD - <developer-feature-label>
- **Developer label:** <what the developer called this feature>
- **Agent label:** <what the agent/session called this feature>
- **Changes:**
  - <one concrete change>
  - <next change>
