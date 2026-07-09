# Changelog

Each commit must add one new entry under `## [Unreleased]` before committing.

## [Unreleased]

### 2026-07-09 - Agent status memory optimization
- **Developer label:** Agent status memory optimization
- **Agent label:** Agent status memory and scan-path optimization
- **Changes:**
  - Removed 300ms active-agent full rescans; rely on hook directory watcher plus a 5s background poll.
  - Shrunk transcript tail reads (200KB → 48KB), capped recent transcripts per cycle, and cached path listings.
  - Consolidated pending/turn/prompt transcript enrichment into one analysis pass per rescan.
  - Narrowed FSEvents to `~/.kannu/agent-status` and `~/.cursor/projects` (dropped Cursor Application Support watches).
  - Limited composer metadata to cached headers instead of scanning every workspace `state.vscdb` each cycle.
  - Avoid republishing traffic-light `@Published` state when values are unchanged.
  - Fixed yellow during WebSearch/AskQuestion: treat trailing transcript `user` after a gated tool as still pending, refresh those sessions on hook-only rescans, and broaden hook v11 tool-name detection.
  - Rewrote awaiting-input (hook v13): yellow only on `preToolUse`/`beforeMCPExecution` for gated tools; sticky until `postToolUse`/`stop`; never demote yellow to thinking/green in transcript enrichment; exclusive yellow vs green UI.
  - Replaced sed-based hook field extraction with a Python status writer so Settings → Install cannot ship a broken shell script.
  - Fixed yellow timing (hook v14): WebSearch approval happens before `preToolUse`, so yellow is driven by transcript pending / `afterAgentResponse`; WebSearch `preToolUse` clears to green (tool running).
  - Fixed stuck traffic-light pulse: `repeatForever` animations started via `withAnimation` were never cancelled when a dot deactivated, so a dimmed green dot kept pulsating next to the lit yellow; switched to a value-driven `.animation` so the pulse stops the moment a dot dims.
  - Fixed yellow for real (hook v15, verified working): measured hook timing showed `preToolUse` fires when the approval card is SHOWN (not after approve), so gated tools (WebSearch/WebFetch/AskQuestion) now write `awaiting_input` on `preToolUse`/`beforeMCPExecution` and flip back on `postToolUse`/`postToolUseFailure`; added `postToolUseFailure` to installed Cursor hooks.
  - Monitor now treats the hook file as sole authority for yellow: removed transcript-based promotion/demotion of `awaiting_input` and the 1s active transcript polling timer (hook watcher reacts instantly, less CPU/memory).

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
