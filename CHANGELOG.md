# Changelog

Each commit must add one new entry under `## [Unreleased]` before committing.

## [Unreleased]

### 2026-08-27 - Document the stable dev-signing identity that keeps TCC grants alive
- **Developer label:** CLAUDE.md dev-build recipe prefers CODE_SIGN_IDENTITY="Kannu Dev" over ad-hoc
- **Agent label:** Grant Accessibility once instead of after every rebuild
- **Changes:**
  - Root-caused the recurring "Accessibility still shows Request access": ad-hoc dev builds sign with the binary's own hash as their identity, so every rebuild orphans every TCC grant (tccd logs `Failed to match existing code requirement` for Accessibility, Media Library, Documents and Full Disk Access alike). The dev-build recipe now prefers a stable self-signed `Kannu Dev` identity, under which grants survive rebuilds; ad-hoc remains the documented fallback with its cost spelled out

### 2026-08-27 - Shorten the idle-red toggle caption
- **Developer label:** One-line caption swap under showAgentStoppedIndicator
- **Agent label:** Nine words instead of a paragraph
- **Changes:**
  - The caption under "Show a red light when no agents are running" now reads "When off, the light hides once agents go quiet."

### 2026-08-27 - Agents pane polish: idle-red toggle clarified, swatch reactivity fixed, neutral footer
- **Developer label:** showAgentStoppedIndicator relabeled with caption + search entry; AgentPaletteSwatchButton/Popover observe their runtime key via Default(key); product-specific footer replaced
- **Agent label:** The confusing toggle explains itself, picked colors reflect on both sides instantly, and the footer stops name-dropping one product
- **Changes:**
  - "Keep red light visible when idle" is now "Show a red light when no agents are running" with a one-line caption explaining the alternative (the indicator disappearing entirely once agents age out) — the behavior itself is unchanged, and it finally has a settings-search entry
  - Fixed the color rows so a newly picked color shows on the left legend dot AND the right swatch in the same instant: the swatch button and popover read their key unobserved, and since their other inputs don't change when their own key does, SwiftUI could skip the re-render and leave the right side stale. Both now observe the runtime key directly
  - The Traffic Light footer no longer over-explains via one product's mechanics; it reads "The yellow light is most reliable when hooks are installed."

### 2026-08-27 - Caffeinate hardened: exhaustive regression tests, pipeline shape, docs
- **Developer label:** caffeinateTransition + hasCaffeinateWorthySession extracted pure; manager becomes decision→transition→command; 10 tests incl. the exhaustive 16-row decision matrix; docs/CAFFEINATE.md
- **Agent label:** The whole feature now reads as a table a debugger can check at a glance, and every row is pinned by a test
- **Changes:**
  - `CaffeinateManager` is restructured into an explicit three-stage pipeline with no behavior change: a pure decision (`shouldKeepAwake`), a pure transition table (`caffeinateTransition` — none/create/release/refresh), and a command stage where each switch arm is one or two IOPM calls. The session-activity predicate is extracted as `hasCaffeinateWorthySession`. Everything except the syscalls themselves is now Foundation-only and tested
  - `CaffeinateDecisionTests` grows to 10 tests: the exhaustive 16-combination decision matrix (any future arbitration edit changes an explicit row), the full transition table including both refresh directions and the unknown-held-mode case, and session-predicate fixtures (invisible, simulation IDs, stopped-only, mixed lists, empty). Negative-verified: flipping the refresh row breaks 3 assertions. Suite is 58 tests
  - New `docs/CAFFEINATE.md`: the two tables verbatim, the exact log-stream and pmset debug commands (including the em-dash grep gotcha in the assertion names), and the deliberate non-behaviors — display sleep untouched, no quit handler because powerd reclaims assertions on any exit, no subprocess ever. The manager's header comment now points there instead of restating prose

### 2026-08-27 - Caffeinate audit: mechanism confirmed solid, four flow defects fixed
- **Developer label:** Feature-off override + enableAgentStatusFeature subscription; bounded retry on assertion-create failure; mode-tracked assertion reason; onboarding seed; pure shouldKeepAwake + 4 tests
- **Agent label:** Caffeinate can no longer strand itself behind hidden controls, lie about its mode, or die silently on a failed assertion
- **Changes:**
  - Audit verdict first: the core was verified live and is sound. Native IOPM assertion (never a caffeinate subprocess, so quit/crash/SIGKILL always release via powerd), correct `options: []` semantics confirmed against the pinned Defaults 9.0.3 source, race-free reconcile, launch re-arm working, and only idle system sleep prevented exactly as the settings copy states
  - Fixed the stranding trap: `reconcile` consulted `smartCaffeinate` without asking whether the agent feature was on. Disabling `enableAgentStatusFeature` with smart stale-on made both modes dead while hiding every caffeinate control (settings section and notch tab are both feature-gated) — no UI path out. The decision now releases whenever the feature is off, and the manager subscribes to the feature key so the flip applies immediately
  - Fixed the terminal failure path: a failed `IOPMAssertionCreateWithName` in manual mode had no event source to retry (the doc comment claimed otherwise) — switch ON, Mac sleeps, forever. Failure now arms one bounded 5s retry that re-runs a full reconcile; any real event cancels it
  - Fixed the stale diagnostic: flipping manual↔smart while held short-circuited at the edge guard, leaving the assertion carrying the other mode's reason string in `pmset -g assertions`. The held mode is tracked and the assertion refreshes on a mode flip
  - Onboarding's caffeinate step now seeds its selection from the stored value instead of always pre-selecting Smart (the `@Default` wrapper was declared but never read)
  - The arbitration is now a pure `AgentTrafficLightMapper.shouldKeepAwake(...)` pinned by 4 new tests (feature-off override, smart-wins, manual-honored, all-off). Suite is 52 tests
  - Documented, unchanged by design: the manual flag stays live-but-hidden while smart is on and re-arms when smart turns off; release latency is bounded by the 30s rescan; `awaitingInput` holds the Mac awake within its 5-minute window and an in-flight tool holds it for the process lifetime

### 2026-08-27 - Traffic-light state colors become user-selectable from a curated palette
- **Developer label:** AgentTrafficLightPaletteColor enum (10 hues, ExternalDisplayStyle idiom) + three Key values; palette popover with taken-swatch blocking; all render sites read the palette
- **Agent label:** Pick your own Active/Awaiting/Stopped colors, and no two states can ever share one
- **Changes:**
  - The three agent-state colors are now chosen from a curated 10-hue palette in Settings > Agents > Traffic Light. Deliberately a closed set instead of a free color picker: a swatch already assigned to another state is disabled with a tooltip naming it, so duplicate state colors are impossible by construction. This also makes the lights genuinely distinguishable for red-green colorblind users who move away from the defaults
  - Defaults reproduce the classic green/yellow/red exactly, including the expanded panel's hand-tuned neon values; non-default hues get saturated neon variants so the glow rendering still reads. The dim state remains a 20% wash of the assigned hue, and the inactive grey stays fixed
  - Every render site reads the palette through observed settings — the closed-notch dots (both Classic and Minimal styles), the expanded panel's neon badges and state text, the Settings live preview, and the legend rows, which now double as the pickers. A Reset Colors button restores the defaults and disables itself when they're already active
  - New settings are searchable ("Active color", "Awaiting input color", "Stopped color", "Reset traffic light colors") with scroll-to-highlight

### 2026-08-26 - Extract the Claude reconciler into the tested mapper (the REGRESSIONS.md refactor)
- **Developer label:** reconcileClaudeSessions moves verbatim to AgentTrafficLightMapper; replacing* builders follow; 8 new ClaudeReconcilerTests
- **Agent label:** The merge that broke three times is now pinned by tests that fail when a field is dropped
- **Changes:**
  - The Claude hook/passive reconciler — inline in a private monitor method and unreachable by the logic test target through all three of its historical regressions — moves verbatim to `AgentTrafficLightMapper.reconcileClaudeSessions(...)` in `AgentTrafficLightState.swift` (Foundation-only, already compiled into KannuTests). The monitor now delegates; the `replacingChatName`/`replacingProjectName` builders move with it. Pure relocation, no behaviour change
  - 8 new `ClaudeReconcilerTests` pin: the entry-7 field set (all four passive-inherited fields, on both the demote arm and the pass-through arm that lost fields twice), demote-on-dead-PID without passive evidence, no-demote by older passive evidence, long-tool promotion, passive-only append, non-Claude pass-through, and the identity case. The field-set guard was negative-verified: temporarily removing the `hostPID` inheritance fails two tests. Suite is now 48 tests
  - `docs/REGRESSIONS.md` entry 7's guard status updated to exists; entry 5's name-resolution half is explicitly still open (the resolvers span filesystem/SQLite sources and need a seam first)

### 2026-08-26 - Remove 27 orphaned files, 33 dead settings keys, and two unwired feature stubs
- **Developer label:** Verified-zero-reference deletions from the dead-code audit; suppressHoverOpen and toggleClipboardPopover archaeology'd and removed; .gitignore covers *.profraw
- **Agent label:** The codebase no longer carries the removed terminal feature's skeleton or two dozen orphaned views
- **Changes:**
  - Deleted 27 Swift files whose every symbol had zero references, re-verified at deletion time: five empty license-header stubs, the dead AppleScript volume reader, the old status-bar menu (plus its four never-invoked @objc partners in AppDelegate), two removed onboarding steps, the superseded MinimalisticMusicView, test/tip/whats-new leftovers, and six orphaned Shelf/LiveActivity components
  - Deleted 33 dead Defaults keys — including the entire never-shipped terminal feature block (15 keys) with its sizing constants and corner-radius helper — plus 3 commented-out key lines and the enums those keys kept alive (MirrorShapeEnum, ColorPickerDisplayMode, ReminderPresentationStyle). Migration-only legacy keys are intentionally retained
  - Deleted ~12 dead functions (effectiveHideUntilHover had gone dead again after the polarity change inlined it; isMouseHovering; isPointInsideNotchWindow; two "legacy - kept for compatibility" Bluetooth handlers; deviceHasNotch and the status-bar trio)
  - Two "dead" clusters turned out to be unwired features and were archaeology'd per instruction before deletion: suppressHoverOpen was built for the terminal notch (sole caller removed with that feature on 2026-07-07) — deleted along with the five permanently-false guards it left in ContentView; toggleClipboardPopover was superseded by ClipboardPanelManager in August 2025 — deleted along with its unreachable onChange in KannuHeader
  - Deleted 4 dead imagesets (Github, LinkedIn, defaultmusic, logo). chrome.imageset was flagged dead by name-grep but is alive via the generated `Image(.chrome)` symbol — restored, and the build verifies the rest
  - `.gitignore` now covers `*.profraw`; the stray zero-byte `default.profraw` at the repo root is gone

### 2026-08-26 - Cut idle wakeups ~90%: gate the hover poll, make Claude detection event-driven, drop the pgrep forks
- **Developer label:** shouldUseHiddenEdgeHoverPolling gates task lifecycle; Claude dirs join FSEvents watchedPaths with the 1s poll relaxed to a 30s safety net; sysctl replaces pgrep in SystemOSDManager
- **Agent label:** Kannu idles quietly instead of waking ~38 times a second
- **Changes:**
  - The 20Hz hidden-edge hover poll ran for the app's lifetime with its condition checked inside the loop, waking every 50ms per display even when nothing was hidden. The condition now gates the task itself: it starts only when polling applies, exits when it stops applying, and every dependency's onChange re-syncs it (notch state, sneak peek, agent pulses, lock state, the always-show settings, and reveal-deadline expiry)
  - Claude's passive session detection was the stated reason the agent monitor rescanned every second on the main actor (directory scans, JSON parses, sysctl per session, transcript tail reads). The Claude projects and sessions directories now join the existing FSEvents stream, whose callback already invalidates the right caches, so detection is event-driven; the timer relaxes to a 30-second safety net. Trade-off, documented: an agent process that dies without leaving any filesystem trace now takes up to 30s to dim (the dead-PID reconciler runs on every rescan, whatever triggers one). Also stopped forcing `forceRefresh` on the rescan path, which had defeated the 1.5s transcript cache every second while Cursor ran
  - `SystemOSDManager`'s watcher forked `/usr/bin/pgrep` 6.7 times per second on macOS 15 and earlier (the process the doc comment itself apologized for). PID lookup is now an in-process `sysctl(KERN_PROC_ALL)` walk, verified live against real processes; `isOSDUIHelperRunning` reuses it

### 2026-08-26 - Fix nine race conditions and the hover livelock (full-repo concurrency audit)
- **Developer label:** Queue-confine SystemVolumeController state; cancel the orphaned OSD disable task; kill AudioTap resurrection; fd-by-value cancel handlers x2; stale-task handle clobbers x3; TOCTOU hook-file deletes; willSet deferral; RT-thread counter removed; hover-exit livelock
- **Agent label:** The island can no longer stick revealed, HUD suppression can no longer strand a frozen helper, and every audited data race is closed
- **Changes:**
  - `SystemVolumeController`'s device/element state was written from both the main thread and the CoreAudio listener queue with no isolation, so a device switch during a key press could target the old device's element. All mutable state is now confined to the listener queue; the public API hops on with `.sync`, keeping multi-step resolve-compare-swap sequences atomic (queue confinement, deliberately not a per-field lock)
  - `disableSystemHUDAsync`'s bootstrap loop (up to ~16s of kickstart+poll+SIGSTOP) was never cancelled and never re-checked `active` — a Settings toggle could SIGSTOP the helper `enableSystemHUD()` had just restored, leaving no HUD at all until relaunch. The task is now tracked, cancelled on every disable path, and re-checks `active` before each SIGSTOP
  - A debounced `AudioTap` restart survived `stopCapture()` and rebuilt the CoreAudio tap plus its 60Hz timer with the waveform feature off. The pending work item dies with the stop and re-checks the feature flag. Also removed `callbackCount`, an unsynchronized global incremented on the CoreAudio realtime thread whose periodic log allocated on that thread
  - Two `DispatchSource` cancel handlers (`SystemTimerBridge`, `CursorAgentStatusMonitor`) re-read `self`'s fd at run time; because `cancel()` only enqueues the handler, an off-to-on toggle made them close the replacement watcher's freshly recycled descriptor, silently killing the timer mirror or the sub-100ms hook watcher until relaunch. Both now capture the fd by value (the pattern `DownloadManager` already used) and the explicit closes in stop() are gone
  - Three music-control-window tasks in `ContentView` nilled their own handle after completing, clobbering the variable that may already have held their replacement — orphaning it beyond cancellation so the floating window could present after conditions that should hide it. The self-nils are gone and each body re-checks cancellation on the main actor
  - The monitor could delete a hook status file that the agent's atomic `os.replace` had refreshed between read and delete, vanishing a live session until the next tool boundary. All three delete sites now re-stat and skip when the file changed since it was judged
  - `$notesLayoutState`'s resize sink was missing the willSet deferral its `$currentView` sibling documents, animating one wrong-height frame per layout change
  - The hover livelock: the 50ms hidden-edge poll compared against `isHovering`, which only flipped inside the 100ms exit debounce — every tick cancelled and re-armed the debounce, so the exit never ran and the island stuck revealed in the default configuration. Hover-exit state and the 5s linger now apply synchronously; the debounce keeps only the open-notch close. Region-hover also cancels the reveal countdown so a running countdown can't hide the island mid-hover
  - The three Cursor parser/store caches are now `@MainActor` so any future off-main parsing becomes a compile error instead of a race; `AgentSessionLogParser` documents why it stays nonisolated (logic test target)

### 2026-08-26 - Hide-until-hover becomes the default, agent lights auto-collapse, settings polish
- **Developer label:** Inverted alwaysShowOnNonNotchDisplays polarity with migration; unified 5s reveal window incl. notched-display band; strict heartbeat gating; permission-store activation refresh; native swatch color picker; settings copy pass
- **Agent label:** The notch stays out of the way until hovered or an agent acts, on every display type, and Settings got a cleanup
- **Changes:**
  - Non-notch displays now hide the notch by default and reveal it on hover, like the auto-hiding menu bar. The old opt-in `hideNonNotchUntilHover` is replaced by an opt-out `alwaysShowOnNonNotchDisplays` (plus per-display overrides in the same polarity), with a one-time migration that preserves anyone's explicit legacy choice inverted; users who never touched the setting move to the new default deliberately. Settings toggle reads "Always show on non-notch displays"; the search-index entry follows the exact new title
  - One shared 5-second reveal window (`notchRevealHoldSeconds`) replaces the two 3-second constants, and hover-out now lingers for that window instead of hiding immediately. This reverts the earlier 6→3s reduction by explicit user decision
  - Notched displays no longer keep the agent traffic-light band expanded for as long as a session exists: the band shares the same activity-refreshed window, showing ~5s on session changes and state transitions, then collapsing even mid-run (strict mode — the running-agent heartbeat no longer refreshes the window; `physicalNotchAgentBandFollowsHeartbeat` flips it back if wanted). Hover, notch-close and music-pill hosting all re-arm cleanly so no stale deadline can strand the band
  - `AccessibilityPermissionStore` refreshes on every app activation and also polls after "Open Settings" — previously a grant made directly in System Settings was never noticed (polling ran only for 15s after the in-app prompt), leaving the Agents tab's callout stuck on "Request access". The Agents and Controls panes also refresh on appear
  - "Customize physical notch width" no longer leaves its sliders editable while the toggle is off doing nothing: dependent controls now disable and dim until the parent is on, the System Settings convention
  - Removed settings rows that only echoed state shown elsewhere (Agents "Current State" duplicated the live preview above it; Shelf "Currently selected" duplicated the picker), rewrote every user-facing mid-sentence em-dash as a plain sentence, and shortened the long Media/Lock Screen captions to one line each
  - The color picker rows (notch fill, timer solid, preset accent) now open a native swatch popover: preset grid, screen eyedropper via `NSColorSampler`, and the existing color panel behind a Custom well. No third-party dependency; same row API and the same `Key<Color>` persistence

### 2026-08-23 - Granting Accessibility now takes effect without restarting Kannu
- **Developer label:** Arm the media-key-tap health monitor on failed creation too, and retry creation while trusted with no tap
- **Agent label:** The first-run path — grant Accessibility while Kannu is running — now works
- **Changes:**
  - The health monitor added earlier today was only started after a *successful* tap creation, so the case it most needed to cover — the tap failing to create at launch because Accessibility isn't granted yet, which is every first-run user — left no retry armed. Granting permission while the app ran was noticed by nothing (the Settings granted-branch only fires with that pane open), so the grant silently required a restart. `start()` now arms the monitor on the failure path as well, and logs "waiting for Accessibility; will retry automatically" so the log tells the story: waiting → granted → rebuilding → confirmed live
  - `verifyTapHealth` also retries creation when trusted but no tap exists — covering a transient `tapCreate` failure or the silent-disable race, which a trust-transition check alone would never catch

### 2026-08-23 - Suppress the macOS 26 system HUD the only way that still works
- **Developer label:** Control Center OSD reality check: version-gate the OSDUIHelper machinery, make the media key tap self-healing and provable, hide Kannu's HUD when interception is not live
- **Agent label:** No more two HUDs at once, and no more pointless background polling on macOS 26
- **Changes:**
  - macOS 26 moved the volume/brightness OSD out of `OSDUIHelper` and into Control Center — confirmed live, it is drawn from subsystem `com.apple.controlcenter`, category `system-banners`, via `showOSD:` (58 volume and 23 brightness OSDs logged in two hours on a machine where `OSDUIHelper` was not even running). Kannu's entire suppression layer was SIGSTOPing a process that no longer draws anything. Control Center cannot be suspended — it is the menu bar — so **media key interception is now the only mechanism that suppresses the system HUD**, on every macOS version
  - `SystemOSDManager` no longer kickstarts `OSDUIHelper`, polls `pgrep` every 150 ms, or spawns `killall` per volume change on macOS 26+. It had been *starting* a process that was not running purely so it could freeze it. A helper that happens to be alive is still SIGSTOPed opportunistically, and `restoreSystemHUDForTermination()` is unchanged. This removes a permanent background poll and its subprocess churn from every Tahoe user's battery
  - The media key tap had no retry path: if it failed to create (no Accessibility) it was never attempted again, and `SettingsView` handled permission being *lost* but never *granted* — so granting Accessibility only took effect after restarting Kannu. `start()` now rebuilds a tap that exists but is dead, a low-frequency health check rebuilds on any Accessibility trust transition, and the Settings granted-branch re-arms it immediately
  - Added a proof-of-life signal: `hasObservedMediaKey` is set only when the tap actually delivers a media key. Per the documented silent-disable race, a re-signed binary launched through Launch Services can hold a tap that is non-nil and reports enabled yet never fires, with no callback for it — so a non-nil tap is not evidence of anything
  - Kannu now stands down instead of stacking: when volume interception is not provably live, macOS is handling the key and drawing its own HUD, so Kannu no longer draws a second HUD showing the same number. It recovers by itself, since an intercepted key sets the proof before the HUD path runs. Brightness gets the same treatment but only where interception was intended — observe-only and third-party DDC modes hand the key to macOS by design and keep their HUD
  - Accessibility callout copy rewritten; it described a bezel that no longer exists on macOS 26
  - Not shipped, documented instead: `defaults write com.apple.controlcenter EnableSystemBanners -bool false` reverts macOS globally to the pre-Tahoe OSD path, but it changes a system-wide setting and is reported to stop working on macOS 27

### 2026-08-23 - Fix Cursor zero-usage weeks, stale-device volume HUD, and bezel-suppression gaps
- **Developer label:** Cursor zero-usage week is a valid snapshot + silent-branch instrumentation; volume device re-resolution per key press; CGEvent tap self-heal, SIGCONT-aware OSD watcher, HUD restore on quit
- **Agent label:** Cursor no longer says "Token totals unavailable" after a quiet week, the volume HUD can't display a stale device's level, and the native macOS bezel stays suppressed while Kannu runs — and comes back when it quits
- **Changes:**
  - `CursorUsageEventsClient` treated a successfully fetched week with zero token usage as a failure (`return nil`), so a user who hadn't used Cursor in 7 days fell through to the quota-only snapshot and saw "Token totals unavailable (no local logs)". A fetched-and-parsed zero week now returns a valid "0 tokens" snapshot. Live capture confirmed the API schema is unchanged (`tokenUsage` intact on token-based events; absent by design on `INCLUDED_IN_PRO` events) — this was never a Kannu regression, just misclassified emptiness
  - That branch was also the only nil-path with no logging. It now logs event/rejection counters and key names (names only, never values), so a future Cursor schema change shows up in `log show` instead of silence. Per-event token decoding moved to a new dependency-free `CursorUsageEventDecoder`, pinned by 5 new unit tests (fixtures from the live response, anonymized). UI copy shortened to "Token totals unavailable" — Cursor's path is HTTP, not local logs
  - `MediaKeyInterceptor` never handled `tapDisabledByTimeout`/`tapDisabledByUserInput`, so a single OS-side timeout killed media-key interception silently and permanently (recovery was impossible: `updateTapState` compared against a stale flag and `start()` early-returned) — macOS then handled the keys and the native bezel returned. The callback now re-enables the tap on those events, and `updateTapState` compares against `CGEvent.tapIsEnabled` (real state)
  - The OSDUIHelper suppression watcher re-STOPped only when the PID changed; an external `SIGCONT` on the same PID defeated it for the session. The tick now also checks the run state via `proc_pidinfo` (a syscall, no extra subprocess) and re-STOPs a resumed helper
  - Quitting Kannu left OSDUIHelper SIGSTOPed forever — no volume/brightness HUD at all until relaunch. `applicationWillTerminate` now calls a new synchronous `restoreSystemHUDForTermination()` (SIGCONT; the async restore path can't run during teardown)
  - `SystemVolumeController` could read/write a stale device forever: the default-device listener was the only updater of `currentDeviceID`, and `installDefaultDeviceListener` marked itself installed even when registration failed. That made the HUD show the old device's level (e.g. 80) while the real output sat at 100. `adjust`/`toggleMute` now re-resolve the default device per key press (one HAL read), and a failed listener registration stays retryable
  - Known limitations, documented not fixed: DDC-integration brightness keys pass through to macOS; the watcher's ≤150 ms respawn window; a SIGSTOP landing mid-render can freeze a bezel frame; volume listeners on former devices aren't removed (duplicates are harmless)
  - `.githooks/pre-commit` hung on every commit, blocking the repo entirely. Its two emptiness checks used `${var//[[:space:]]/}`, whose cost in bash 3.2 — macOS's `/bin/bash`, which is what `#!/usr/bin/env bash` resolves to here — grows superlinearly: measured 0s at 2 KB, 3s at 8 KB, 31s at 20 KB, and the `[Unreleased]` section has now reached 78 KB, so the hook effectively never returned. Every changelog entry wound this tighter. Both checks now use `grep -q '[^[:space:]]'`, the idiom the rest of the hook already uses; verdicts verified identical on empty/whitespace-only/populated input, and the hook now finishes in 1s

### 2026-08-21 - Click-through lands on the exact chat for stopped Claude sessions
- **Developer label:** claude://resume deep link for stopped sessions + Accessibility callout in Agents settings
- **Agent label:** Clicking a red Claude chat now opens that exact conversation in Claude Desktop
- **Changes:**
  - Stopped Claude sessions were deliberately inert; now they are clickable when Claude Desktop is installed. Clicking opens `claude://resume?session=<uuid>` — Desktop imports the on-disk transcript and shows the chat exactly where it left off. Verified live: the attached host process just idles, no prompt is sent, nothing executes until the user types, and Kannu keeps showing the session as stopped
  - Live sessions are deliberately never deep-linked. Verified against Claude Desktop 2.1.222: `claude://resume` on a session that already has a running host spawns a second `claude --resume` consumer of the same transcript instead of focusing the existing view; the alternative `claude://code/<id>` route only accepts cloud session ids. So live sessions keep activating their host app, and the deep link is additionally gated on the session's display state being inactive — a live session that transiently lacks a pid stays inert rather than risking a duplicate
  - The conversation id is strictly UUID-validated before it is placed in a URL, and the claude:// handler is only trusted when it resolves to Claude Desktop's bundle id — a stray scheme handler cannot capture clicks
  - Window-level raising for terminal- and IDE-hosted sessions silently never ran because Kannu had no Accessibility permission and nothing surfaced that. The Agents settings section now shows the standard permission callout (request + open System Settings) when Accessibility is missing, framed as optional: clicks still land in the right app without it

### 2026-08-21 - Fix click-through being dead for every hook-tracked Claude session
- **Developer label:** Reconciler inherits cwd and hostPID from the passive session, not just names
- **Agent label:** Clicking a Claude chat row actually opens its terminal now
- **Changes:**
  - Click-through never worked for Claude Code in practice. `AgentSessionOpener.target(for:)` needs a live pid to walk to the hosting terminal, `hostPID` is set only on the passive transcript path, and hook status files carry no pid — so when hooks are installed (the normal case) the hook session shadows the passive one, `hostPID` is nil, and the row is silently inert with no cursor or tooltip
  - The reconciler's inheritance helper carried `chatName` and `projectName` across that shadowing but not the new locator fields. It now carries `cwd` and `hostPID` too, and is renamed `inheritingPassiveData` since it is no longer names-only. Inheriting the pid is safe by construction: the passive path only sets it while the process is provably alive, so a dead session still inherits nil and stays correctly non-clickable
  - Verified on the live machine rather than synthetically — the previous verification passed while the feature was broken because it exercised a passive-only session. Instrumented the reconciler: with the fix all four displayed Claude sessions carry a real `hostPID`; with it removed, three of four are nil (the fourth being the one session with no hook file). Confirmed those pids resolve through the parent-walk to the hosting app
  - `docs/REGRESSIONS.md` gains entry 7 for the hook-shadows-passive pattern — three occurrences across two fields, all invisible to tests because the reconciler is not reachable from the logic-only target. Two entries now point at the same refactor

### 2026-08-21 - Record the recurring regressions and enforce the invariants
- **Developer label:** docs/REGRESSIONS.md, mirror-drift pre-commit guard, regression-guard tests, CI on development
- **Agent label:** The rules that keep re-breaking now fail a check instead of relying on memory
- **Changes:**
  - New `docs/REGRESSIONS.md`: six invariants that have each broken more than once, with the commits that prove it, the structural reason each recurs, and the guard that catches it. Plus a danger-zone map of the four churn hotspots (18/18/17/8 commits) and a merge-hygiene section covering the divergent-branch pattern that made us pay for the same fix twice. Linked from `CLAUDE.md` and `CONTRIBUTING.md`
  - The hook-script mirror invariant is now enforced by `.githooks/pre-commit`, which compares the `KANNU_HOOK_SCRIPT_VERSION` markers in the embedded and mirrored copies. Prose alone had already failed: `CLAUDE.md` said "never let them drift" and it drifted twice afterwards. Verified in both directions — the guard rejected the live drift, then accepted after resync
  - Resynced `scripts/kannu-agent-status.sh` on this branch from the embedded source; it had been stale at v23 against an embedded v24. That mirror is what `install-cursor-hooks.sh` hands users
  - New `KannuTests/RegressionGuardTests.swift` (5 tests): pins the 360s active-staleness window that was once shortened to 15s and broke every hook-only provider mid-tool-call, and pins the tool-name/chat-title sanitation that has regressed five times. Verified the staleness test fails when the constant is set back to 15_000. Suite is now 35 tests
  - CI now also runs on `development`. It triggered on `main` only, while the branch model routes every PR to `development` — so the build and the unit tests never ran on an actual PR
  - Corrected two false statements in `CLAUDE.md`: the pre-commit hook does not build the app (it is bash/awk, milliseconds), and CI's branch coverage is now stated explicitly

### 2026-08-21 - Match the lossy-decode form to the Antigravity branch
- **Developer label:** Inline the UTF-8 fallback instead of a helper so the parser file merges cleanly
- **Agent label:** No behaviour change — removes a merge conflict in the file that carries the false-green fixes
- **Changes:**
  - The previous commit added the lossy UTF-8 fallback as a `decodeLossy` helper, which was tidier but textually diverged from the identical fix already on `feat/antigravity-integration` — turning what should have been a no-op merge into a third conflicted file. That file carries both the `continue` escalation fix and the decode fix, so a mis-resolved conflict there could silently reintroduce the dimming bug. Inlined to match the branch verbatim (including the hoisted `let data`); the development-only `limit:` parameter merges cleanly on its own. Verified: parser file no longer conflicts, 30 tests still pass

### 2026-08-21 - Harden the false-green fix: escalation abort, dead-PID key, unwired tests
- **Developer label:** continue-on-decode-failure + lossy UTF-8, live-session dead-PID reconciliation, .unknown means working, KannuTests in scheme and CI
- **Agent label:** A live session can no longer be dimmed by an unreadable transcript read, and the unit tests actually run
- **Changes:**
  - The tail-window escalation loop `break`-ed when a read returned nil, abandoning the wider windows — whose byte offsets are independent and would decode fine. Since `readTrailingLines` seeks to an arbitrary offset and decoded strictly, any window boundary landing inside a multi-byte character (em dashes, arrows and emoji are everywhere in transcripts) produced `.unknown`, which is cached against an unchanging (mtime, size). With the new demote arm acting on passive verdicts, that dimmed a correctly-green running session. Now `continue`, plus a lossy decode fallback at all three read sites, matching the fix already on the Antigravity branch so the hunks merge as no-ops
  - `deadPIDConversationIDs` is keyed by conversation id while `~/.claude/sessions/` is keyed by PID, so `claude --resume` after a crash left the live session permanently marked dead — and `processDead ||` bypasses the reconciler's timestamp guard, flashing red at the moment a prompt is submitted. Live conversation ids are now subtracted from the dead set before it is returned
  - `passiveClaudeState`'s `.unknown` arm returns thinking unconditionally instead of idle: it is only reached for a live process whose tail could not be parsed even after escalation, and calling that idle is destructive now that the demote arm consumes passive verdicts
  - The 29 unit tests never ran: `Kannu.xcscheme`'s TestAction listed only `KannuUITests`, and CI ran `xcodebuild build`. `KannuTests` is now in the scheme, and CI gained a test step against the logic-only target
  - Added a regression test whose fixture deliberately straddles a multi-byte character on the 16 KB window boundary; verified it fails against the pre-fix reader and passes after. Suite is 30 tests, 0 failures

### 2026-08-21 - Fix false-green Claude sessions (interrupts, stale tails, dead processes)
- **Developer label:** Truthful Claude transcript-tail parsing plus staleness/demotion in the passive-hook merge, with a new KannuTests unit bundle
- **Agent label:** An interrupted or killed Claude session no longer glows green forever
- **Changes:**
  - `AgentSessionLogParser.claudeTailState` now recognises Esc-interrupt records (`[Request interrupted by user…]` as string content, `text` block, or inside a `tool_result`) as `turnFinished` — Claude Code's Stop hook does not fire on user interrupt, so the trailing `user` record used to read as "owes a response" and the light stayed green for as long as the process lived
  - Any terminal `stop_reason` (`max_tokens`, `refusal`, future values — not just `end_turn`/`stop_sequence`) now ends the turn; only `nil`/`tool_use`/`pause_turn` remain mid-turn
  - Tail reads escalate 16 KB → 256 KB → 1 MB when the verdict is `.unknown` (real records reach hundreds of KB and used to truncate into unknown), return the deciding record's own timestamp, and are cached against (mtime, size) so the 1 Hz rescan stats instead of reads quiet sessions
  - New `AgentTrafficLightMapper.passiveClaudeState`: the tail verdict is consulted before the mtime shortcut (post-turn `ai-title`/bookkeeping writes no longer repaint green), a passive `working` verdict ages out after 10 minutes without evidence (`toolInFlight` never ages — long tools stay green), and a finished turn ages from the deciding record's timestamp so bookkeeping writes cannot re-flash red
  - The hook/passive reconciler gained a demotion arm: a hook file stuck on `executing`/`thinking` (interrupt, SIGKILL, crash — no Stop/SessionEnd ever arrives) is demoted when the passive side has fresher contrary evidence or the PID is dead, including dead sessions too old for a passive card. The existing long-tool resurrection path is unchanged and now safe, since passive green states are verified or bounded
  - `looksLikeToolName` moved from `CursorAgentStatusMonitor` to `AgentApprovalGatedTools` (pure, Foundation-only) with a forwarding shim, so the mapper and tests don't drag in the monitor
  - New `KannuTests` unit-test target (scheme `KannuTests`) covering the tail parser (interrupt variants, stop reasons, truncation, window escalation) and the passive-state ladder (29 tests)
### 2026-08-20 - Click-through from agent chat rows to the hosting app
- **Developer label:** Session rows open their app: bundle-id activation, project-aware launch, terminal parent-walk, AX window raise
- **Agent label:** Click a chat in the notch and land in the app — and where possible, the right window
- **Changes:**
  - Session rows and the primary card in the notch's agent panel are now clickable when the hosting app can be located, with a pointing-hand cursor and an "Open in <app>" tooltip; rows with nothing to open offer no affordance at all. The notch closes after a successful open
  - GUI IDE sessions (Cursor / VS Code / Antigravity) activate the running app by bundle id; when the IDE isn't running and the session knows its working directory, it launches the IDE *on that project*
  - Claude Code sessions walk the agent process's parent chain (same sysctl idiom as `isClaudeProcessAlive`; `kp_eproc.e_ppid` was already in the struct being read) to whatever GUI app actually hosts the terminal — Terminal, iTerm2, Warp, an IDE's integrated terminal, or Claude Desktop's — and activate that. The `com.anthropic.claude` bundle id is deliberately not used: it's the desktop chat app, not Claude Code
  - When Accessibility is already granted, the specific window whose title matches the session's project is raised before activation; silently skipped otherwise — no prompts, and the existing Settings card remains the place to grant it
  - `AgentSessionStatus` gained `cwd` and `hostPID` locator fields, threaded through every merge/repair/copy site so they survive the session pipeline. Claude passive sessions attach the pid and cwd that were already parsed and discarded; a dead pid never makes a row clickable
  - Hook script v28: status files now store the full working directory (`workspace_roots` root or `cwd`), preserving it across events that don't carry one; `scripts/kannu-agent-status.sh` resynced from the embedded source. Verified live: race harness still 0/200 downgrades and 0 torn reads, and this session's own status file gained its cwd on the first post-migration event

### 2026-08-20 - Agents-first settings and a tighter agent panel header
- **Developer label:** New "AI Agents" sidebar group with Agents + Usage panes; merge the notch panel's header line
- **Agent label:** Agent settings lead the sidebar, LLM providers get their own Usage pane, and the notch panel saves a line
- **Changes:**
  - Settings sidebar now opens with an **AI Agents** group at the top: **Agents** (renamed from "Agent Status"; its first section is now "Monitoring") and a new **Usage** pane. The window also lands on Agents by default — the product's core pane greets the user instead of General
  - The LLM usage monitor toggle and provider list moved out of the Stats pane (where they hid under Developer) into the new Usage pane, mirroring how the notch already presents Agent Status and Usage as sibling tabs. Added the previously missing Antigravity provider toggle — the Defaults key existed but had no settings row anywhere
  - Search entries follow their settings: provider searches now land on the Usage pane; the smart-caffeinate deep link is unaffected (highlight ids derive from unchanged case names)
  - Notch agent panel: the "Recent chats" label moved up onto the caffeinate line — label left, cup right — filling the empty gap and saving a row; the label hides in the empty state where there is nothing to label

### 2026-08-20 - Fix the launch freeze that made the caffeinate toggle look dead
- **Developer label:** Move first TCC touches (Bluetooth, ~/Downloads) off the launch path; visible ON states
- **Agent label:** The app no longer freezes at launch behind permission dialogs, and ON always looks ON
- **Changes:**
  - Root cause of "toggle on but nothing lit": `AppDelegate.init` eagerly builds singletons whose first access to a TCC-protected resource blocks the main thread until the permission dialog is answered — `BluetoothAudioManager.checkInitialDevices()` (Bluetooth) and, once past that, `DownloadManager` enumerating `~/Downloads` (Files & Folders). Every dev rebuild re-asks because the ad-hoc signature changes, so post-rebuild launches froze before `applicationDidFinishLaunching` — `CaffeinateManager` never spun up, and the switch showed ON with no assertion behind it
  - Both managers now take their first protected-resource touch on a background queue: launch never blocks, the dialog can sit unanswered indefinitely, and each manager finishes its setup (device discovery / folder monitoring) when the permission round-trip resolves. `DownloadManager` gained an explicit warm-up gate because its Defaults subscription fires an initial event that previously started monitoring on the main thread anyway, bypassing the sequencing
  - The manual caffeinate switch is now tinted orange when on — the default accent at `.mini` size was nearly indistinguishable from off against the dark notch. One colour consistently means "caffeinated": the switch shows intent, the cup still shows assertion truth
  - The smart indicator's sparkle now stays lit (accent) whenever smart mode is enabled, turning orange while actually holding — an idle smart mode previously looked identical to everything-off

### 2026-08-20 - Caffeinate indicator: working tooltip and a real settings deep-link
- **Developer label:** Fix nested-.help shadowing, deep-link the smart indicator to its settings row
- **Agent label:** Hovering the cup explains it, clicking it lands exactly on Smart caffeinate in Settings
- **Changes:**
  - The smart-mode indicator's tooltip never showed over the cup glyph itself: `cupIcon` carried its own `.help` inside the Button that also had one, and the innermost tooltip wins for the region it occupies. Split into a bare `cupImage` (used inside the Button) and `cupIcon` (standalone, keeps its tooltip for the manual-mode row) — the Button's "click to change in Settings" text now covers its whole hit area
  - Clicking the indicator used to open Settings on whichever tab was last viewed: `SettingsView` is built once per app run, so its tab `@State` persists across opens, and `showWindow()` never touched it. New `showWindow(navigatingToAgentStatusHighlight:)` drives the existing search-bar scroll-and-pulse machinery (`SettingsHighlightCoordinator`, now a shared singleton with an external `requestAgentStatusNavigation` entry point) — Settings opens on Agent Status, scrolled to the Smart caffeinate row with the standard 2-second highlight pulse
  - Tab selection now reacts to navigation requests in one place (a body-level `onReceive`); the search bar's handler no longer sets the tab separately, so in-window search and external deep links cannot drift apart
  - The highlight id lives in one typed constant (`SettingsDeepLink.smartCaffeinateHighlightID`) used by the settings row, the search index, and the notch button alike — previously the same string literal in three places
  - Pointing-hand cursor on hover and a VoiceOver hint ("Opens caffeinate settings") on the indicator, per HIG affordance for icon-only controls
  - Re-audited the whole flow for races: the deep link is a single synchronous main-thread call chain with no suspension points, and repeated rapid clicks only extend the highlight pulse (the coordinator cancels its prior clear-timer before scheduling a new one)

### 2026-08-20 - Smart caffeinate and manual caffeinate modes
- **Developer label:** Two-mode caffeinate (smart auto-scoped / manual), adaptive notch control, onboarding choice
- **Agent label:** Choose between a manual keep-awake switch and automatic keep-awake while agents run
- **Changes:**
  - `CaffeinateManager` now has two modes. **Manual** (`caffeinateEnabled`): the notch switch holds a system-sleep assertion unconditionally while on. **Smart** (`smartCaffeinate`, Settings › Agent Status): the assertion is held automatically while any visible agent session is in an active run and released when every run stops; the manual switch is hidden from the notch and replaced by a cup+sparkle indicator that opens Settings when clicked
  - Race-hardening: all three inputs (both Defaults keys and the agent session list) are treated as bare wake-up signals with no captured payloads — `reconcile()` re-reads live state on the main actor at execution time, so any burst of toggles or session events converges on the truth regardless of task ordering, and the edge-guarded synchronous IOPM transitions can never interleave
  - Replaced `print` with `os.Logger` (subsystem `com.kannu.app`, category `Caffeinate`) — the previous logging was unobservable in `open`-launched apps, which made a launch issue undiagnosable
  - Tooltips on the cup icon in every state; onboarding gains a "Keep the Mac awake?" step (smart recommended vs manual) after the traffic-light style choice
  - Diagnosed during testing (fix tracked separately): `AppDelegate` initializes `BluetoothAudioManager` synchronously before `applicationDidFinishLaunching`, and its `IOBluetoothHostController` access blocks the main thread on a TCC permission round-trip — a launch with no cached Bluetooth TCC decision freezes until the dialog is answered, and bare-executable launches abort with a TCC violation

### 2026-08-20 - Caffeinate toggle in the agent panel
- **Developer label:** Auto-scoped keep-awake via IOPM assertion, toggle in the Agent Status panel
- **Agent label:** The Mac stays awake while agents run — and only while they run
- **Changes:**
  - New `CaffeinateManager`: when armed, holds a `PreventUserIdleSystemSleep` assertion while at least one visible agent session is in an active run (thinking / executing / awaiting input — the same definition the traffic light uses) and releases it the moment every run stops. Set-and-forget: an armed toggle with no agents running costs nothing. System sleep only — the display may still sleep; agents keep running behind a dark screen
  - Toggle lives at the top-right of the open-notch Agent Status panel, visible in every panel state. The coffee-cup icon doubles as live status: filled and warm only while the assertion is actually held, outline when merely armed or off
  - The header-less fallback path of the chat list (sessions but no primary) now carries the same "Recent chats" header as the normal path
  - Verified end to end with `pmset -g assertions`: assertion appears while armed with a live agent, disappears on disarm/agent-stop, no leak after quit

### 2026-08-20 - Project-level ART engineering framework
- **Developer label:** Add CLAUDE.md with the ART framework and Kannu engineering standards
- **Agent label:** Claude Code sessions in this repo now start from a shared persona, architecture principles, and repo facts
- **Changes:**
  - New repo-root `CLAUDE.md`: the ART breakdown ceremony (Act as / Request / Terms / Relevant skills, shown before any work), skill-loading discipline with explicit honesty clauses (never invent an unlisted skill, zero skills is valid, failed loads are stated), the Senior macOS Swift Architect persona, product context, architecture principles, and audit/UI/debugging/security/testing rules
  - Ships the executable repo knowledge sessions kept rediscovering: build/run/verify commands (verification vs runnable ad-hoc builds, `open`-only launches, `/usr/bin/log` over the zsh `log` builtin), house conventions (GPL header, `Defaults` key idiom in `Constants.swift`, `String(localized:)`, the `settingsSearchIndex`/`settingsHighlight` pairing, manager singleton shape), and known traps: the building pre-commit hook with its mandatory changelog entry, the `Kannu.debug.dylib` split that breaks binary greps, the stale-build-database false success, eager TCC touches in `AppDelegate.init` freezing launch, `Defaults.publisher`'s initial-fire behaviour, and the embedded-vs-mirrored hook script pairing

### 2026-08-19 - Notch traffic light: no logo, Classic and Minimal styles
- **Developer label:** Remove the provider logo from the closed notch, add a Classic/Minimal traffic light style
- **Agent label:** The notch stops blinking its logo at you, and the light can be one dot instead of three
- **Changes:**
  - Removed the provider logo (and the provider name beside it) from the closed-notch traffic light. In the two-or-more-agent path the logo carried the attention pulse, so a running agent's icon breathed 1.0→1.3 scale continuously for the whole run — the blinking that was reported. Only the state dot animates now
  - The closed notch now always shows exactly **one** light, whatever the agent count. The old multi-agent row rendered a provider icon per session and no lights at all; it is deleted, along with the 30-second linger window that only existed to decide which icons stayed on screen. The state shown is the highest-priority one across all sessions (stopped › awaiting input › executing › thinking), most recently updated chat breaking ties — the precedence that already drove the light
  - New **Classic** / **Minimal** styles: Classic keeps the three dots with the inactive two dimmed; Minimal draws only the dot that is lit, and nothing at all when idle. Selectable in Settings › Agent Status › Traffic Light (with a live preview) and offered as a step during first-run onboarding. Defaults to Classic, so existing installs see no change beyond the logo going away
  - Pulse semantics are unchanged: yellow and green breathe while lit, red pulses for 4 seconds after a run completes and then holds steady
  - Extracted `AgentTrafficLightDots` — the notch, the Settings preview and the onboarding cards all render through the same view, so a preview cannot drift from what the notch actually draws

### 2026-08-19 - Full review pass: security hardening and refresh-seam fixes
- **Developer label:** Hook script v27, fail-loud config merges, legacy credential cleanup, drain floor bypass
- **Agent label:** Verified every PR claim end to end; fixed what the security and race audits confirmed
- **Changes:**
  - A forced refresh parked while another refresh was in flight was silently dropped on drain: `lastRefresh` is stamped at refresh start, so the drained request always re-entered the 10s interactive floor it could not pass — the limits toggle or Refresh press looked dead for up to 3 minutes. The drain now bypasses the floor; it already waited out a full refresh, so this adds at most one request per genuine user action
  - Cards no longer blank to a spinner when the previous result was a failure — an always-visible provider in a failure steady state (Antigravity with no sessions in 24h) strobed a ProgressView on every 30s poll tick
  - Installing hooks over a config file that exists but does not parse (stray comma, JSONC comments) used to rebuild the document from scratch, silently destroying every user-defined hook — and for `~/.claude/settings.json`, the user's whole settings file. All four merge paths now abort with a visible error and leave the file untouched
  - One-time cleanup of the legacy Kannu-owned keychain copy of Claude's OAuth tokens: the persistent copy was replaced by a 60s memory cache, but the deletion code went with it, leaving real token material orphaned in every upgraded install's keychain
  - Hook script v27: `~/.kannu/agent-status` is created 0700 (the files carry session titles and drive the traffic light), and `conversation_id` is capped at 64 chars after sanitisation — an oversized hostile id pushed the status/lock paths past NAME_MAX and killed the hook before it printed its allow response
  - Resynced `scripts/kannu-agent-status.sh` (installed by `install-cursor-hooks.sh`) from the embedded v27 source — it had drifted to v25, which still carried the unlocked read-modify-write and truncate-write races fixed in v26
  - Removed dead `hoveredUnavailable` state and corrected comments still describing the removed "unavailable chip"; the debug log now prints a hand-written case name where interpolating the credential enum could have dumped the whole struct via reflection

### 2026-08-18 - Address the second CodeRabbit review
- **Developer label:** Antigravity uninstall schema, restored signing team, migration coverage
- **Agent label:** Uninstall actually removes Antigravity hooks; release signing identity restored
- **Changes:**
  - `stripEntries` routed only `~/.gemini/antigravity-ide/hooks.json` through the matcher-group stripper; the other two Antigravity locations fell to `stripCursorEntries`, which reads a top-level `command` and matches nothing in a group-shaped entry. Uninstall deleted the script but left live entries in `~/.gemini/config/hooks.json` — the primary path install always writes — so Antigravity ran a command whose script was gone and `checkInstalled` still reported it installed. All three now use the same stripper `stripAntigravityEntries` already used at install time
  - Removed the recursive re-strip inside `stripEntries`; `uninstall(.antigravity)` already visits all three explicitly
  - Restored `DEVELOPMENT_TEAM` in `project.pbxproj`: Debug `3Z7WX43G8Q`, Release `S2WWHQQH2V`. A local Xcode rewrite had set both to a third team — Release controls distribution signing and the Sparkle update chain
  - The hook event-argument migration inspected only the IDE config, which install touches only when it already exists, so a fresh install was never migrated. It now checks all three locations, matching `checkInstalled(.antigravity)`

### 2026-08-18 - Notch skin leak, hook status-file races, Claude quota hardening
- **Developer label:** Layout-only header spacer, locked+atomic hook status writes, read-only Claude credentials
- **Agent label:** Skins cover the whole notch, the traffic light stops losing its urgent state, and usage limits stop 429ing
- **Changes:**
  - Fixed a flat `notchFillColor` patch painted over custom notch skins: the open-notch spacer in `KannuHeader` filled a `NotchShape`-masked rectangle in the middle of the panel, on top of the skin. The panel background already covers those bounds and sits behind the header, so the fill was redundant in every configuration and simply wrong once skins existed — the spacer is now `Color.clear` and purely reserves layout. Dropped the orphaned `notchFillColor` property and `selectedScreenHasPhysicalNotch` helper
  - Serialised the hook status-file read-modify-write behind a per-conversation `flock`. Claude runs matcher-scoped and generic hook groups as parallel processes, so both read the same pre-race state, the `STATE_PRIORITY` merge found nothing to preserve, and the second writer won outright — a yellow "needs you" was silently overwritten by a green "running". Measured at 11 of 200 parallel rounds before the fix, 0 of 200 after
  - Hook status files are now written temp-then-`os.replace` instead of truncate-then-write, so Kannu never reads a half-written file. Measured at 14 torn reads in 4825 before, 0 in 9059 after. Hook script v26; `SessionEnd` also removes the lock file
  - `ClaudeCredentialStore.lookup` cleared the in-flight entry unconditionally after its `await`, which could erase a *successor's* live entry and let a second prompting keychain read start — two stacked approval dialogs. Now identity-checked
  - Collapsed the 429 path's two cooldown `await`s into one atomic actor call; the gap between them let a concurrent success wipe the backoff just installed and relabel fresh figures as stale
  - Claude credentials are now read-only. Refreshing the shared rotating refresh token invalidated the token family and blanked the user's `claude` CLI login

### 2026-08-13 - Address CodeRabbit review on the Antigravity integration
- **Developer label:** Fix Antigravity config clobbering, restore the active-state window, detect the Antigravity CLI
- **Agent label:** Antigravity hooks no longer overwrite user config, long Codex/VS Code runs stay green, CLI-only installs are detected
- **Changes:**
  - `AgentHookInstaller.swift`: `mergeAntigravityHooksConfig` built one document from the IDE config and wrote it to all three locations, destroying user-defined hooks in `~/.gemini/config/hooks.json` and `~/.gemini/hooks.json`. Each location is now merged into its own content; the documented global path is primary and the others are only updated when they already exist. `uninstall` and `checkInstalled` cover all three so we never strip less than we wrote
  - `AgentTrafficLightState.swift`: restored `runningStaleSeconds` / `activeStaleMs` to 360s from 15s — hook-only providers (Codex, VS Code) write no status file during a tool call, so a 15s window marked running sessions as stopped
  - `LLMUsageManager.swift`: Antigravity detection now checks `~/.gemini/antigravity-cli` alongside `antigravity-ide`, so CLI-only installs enable the provider instead of staying silently disabled
  - `ContentView.swift`: extracted `hasActiveMusicSnapshot` as a single computed property — one call site tested `isPlaying` alone while three used the fuller definition, so the agent light blinked in and out of a paused-but-visible music pill
  - `AgentHookInstaller.swift`: the `PostToolUse` entry now passes `thinking`, matching the state the script derives
  - `AgentHookInstaller.swift` + `scripts/kannu-agent-status.sh`: added `quota_exceeded` to `STATE_PRIORITY` in both copies, so a stale `stopped` no longer wins the 2s arbitration and discards the "Quota exceeded" label
  - `KannuHeader.swift`: accessibility label and tooltip for the icon-only refresh button

### 2026-08-09 - Drop Unavailable chips from the Usage tab
- **Developer label:** Drop Unavailable chips from the Usage tab
- **Agent label:** Claude: remove hoverable Unavailable chips; omit failed and fatally unconfigured providers from the card row
- **Changes:**
  - `NotchLLMUsageView.swift`: removed the `inactive` provider list and `unavailableChip(for:)` UI that previously rendered dimmed "Unavailable" chips next to active cards — the Usage tab now only shows providers that are active/usable
  - `UsageProvider.swift`: added `UsageSnapshot.isAuthFailure` / `isFatallyUnconfigured`, and threaded `QuotaFetchResult.isAuthFailure` so signed-out / 401–403 / expired-token failures can be distinguished from transient 429/5xx errors
  - `ClaudeUsageProvider.swift` / `CodexUsageProvider.swift` / `ClaudeQuotaClient.swift` / `CodexQuotaClient.swift`: set `isAuthFailure` on definitive auth failures only (not 429/5xx), and `NotchLLMUsageView.isActiveProvider` now also filters `.success` snapshots where `isFatallyUnconfigured` is true

### 2026-08-09 - Move Usage-tab refresh into the header icon row; drop redundant Claude token counts
- **Developer label:** Move Usage-tab refresh into the header icon row; drop redundant Claude token counts
- **Agent label:** Claude: relocate the Refresh control to an icon-only button beside the clipboard icon in KannuHeader; hide Claude's compact Today/Week token rows since its Session/Week quota gauges already cover that ground
- **Changes:**
  - `NotchLLMUsageView.swift`: removed the labeled "Refresh" text+icon button that lived in its own row above the provider cards
  - `KannuHeader.swift`: added a matching icon-only refresh `Button` (same `Capsule().fill(.black)` 30×30 style as the clipboard button, `arrow.clockwise` glyph) positioned right after the clipboard icon in the header's icon row; only shown while `coordinator.currentView == .llmUsage`; calls `LLMUsageManager.shared.refreshAll(force: true)` and disables itself while `isRefreshing`, matching the exact behavior of the button it replaces
  - `NotchLLMUsageView.swift`: threaded `provider: ProviderID` into `success(_:)` (was called with no provider identity) and wrapped the compact `window("Today", ...)`/`window("Week", ...)` rows in `if provider != .claude`, since for Claude that information duplicates the "Session"/"Week" quota gauge bars already shown above it. Other providers (Cursor, Codex) keep the compact rows unchanged

### 2026-08-09 - Stronger pulse and a completion attention-flash on the closed-notch traffic light
- **Developer label:** Stronger pulse and a completion attention-flash on the closed-notch traffic light
- **Agent label:** Claude: widen pulse amplitude, add a brief full-brightness pulse on session completion before it dims
- **Changes:**
  - `ConditionalPulseModifier` (`AgentTrafficLightLiveActivity.swift`) widened from 1.0→1.15 scale / 1.0→0.75 opacity to 1.0→1.3 scale / 1.0→0.5 opacity, and sped up from 0.8s to 0.7s per cycle — reported as too subtle to read as "breathing" at these icon sizes
  - Added a 4-second "attention window" after a session completes: both `singleAgentRow`'s red dot and `multiAgentRow`'s icon now keep pulsing at full brightness for those 4 seconds instead of dropping straight to the static dimmed/settled state — completion was previously a silent instant dim, easy to miss if you weren't already looking at the notch. Red/yellow/green semantics are unchanged (red still means done, green still means running) per explicit confirmation — this is about making the completion *moment* noticeable, not changing what the colors mean
  - Known limitation, not addressed here: a provider whose hook payload carries no resolvable conversation ID falls back to the literal ID `"default"`, which `AgentTrafficLightMapper.isSimulationConversationID` treats as a test session and drops. That session never reaches the display list, so with two agents running only one appears in the closed notch

### 2026-08-09 - Always surface Agent Status on closed-notch hover when an agent is active
- **Developer label:** Always surface Agent Status on closed-notch hover when an agent is active
- **Agent label:** Claude: remove the Home-only restriction on hover-triggered Agent Status auto-switch
- **Changes:**
  - `ContentView.swift`'s closed-notch hover handler previously only auto-switched `coordinator.currentView` to `.agentStatus` when the current tab was already `.home` — hovering while on Notes/Stats/Timer/etc. never surfaced active agent work. Removed that `currentView == .home` condition; hovering the closed notch now always jumps to Agent Status whenever `agentStatusMonitor.shouldShowTrafficLight` is true, regardless of which tab was last open
  - Investigated the rest of the request (single-agent icon+name+traffic-light, multi-agent icon row with pulse, auto-disappear once done) and confirmed it's all already implemented in `AgentTrafficLightLiveActivity.swift` (`singleAgentRow`/`multiAgentRow`, `ConditionalPulseModifier`, 30s completion linger window) — no change needed there, confirmed with the user that the existing simultaneous-pulse behavior (not an alternating/rotating display) is what was wanted

### 2026-08-09 - Surface Antigravity quota-exceeded state in the notch
- **Developer label:** Surface Antigravity quota-exceeded state in the notch
- **Agent label:** Claude: detect terminationReason/error on Antigravity's Stop hook and label the session "Quota exceeded"; sync the stale standalone hook script copy
- **Changes:**
  - `AgentHookInstaller`'s installed hook script (embedded in `writeScript`) now inspects `terminationReason`/`error` on Antigravity's `Stop` event and, when either mentions quota/rate-limit/resource-exhaustion, writes raw state `"quota_exceeded"` instead of `"stopped"` and sets the session name to "Quota exceeded" — previously a quota-exhausted run looked identical to a normal completion, so it never showed up anywhere
  - No `AgentTrafficLightState` changes needed: an unrecognized raw state already falls back to the same stopped/inactive-by-age lifecycle in `AgentTrafficLightMapper.resolveHookState`, so this is purely additive — the traffic light behaves exactly as before, only the Usage-tab card text (`AntigravityUsageProvider`, which reads the raw state string directly) and the session's chat-name label change
  - Bumped `KANNU_HOOK_SCRIPT_VERSION` 24 → 25 so existing installs pick up the new script automatically via the existing `migrateHookScriptVersionIfNeeded` path
  - `scripts/kannu-agent-status.sh` (the standalone reference copy) had drifted stale at v23 despite two rounds of changes already landing in the installed copy — resynced it to match exactly, plus this change
  - **Unverified assumption:** the exact wording Antigravity puts in `terminationReason`/`error` for a quota/rate-limit stop hasn't been confirmed against a real quota-exhausted run — the marker list (`quota`, `rate_limit`, `rate limit`, `resource_exhausted`) is a best guess from public docs, not observed output. Please check the actual `~/.kannu/agent-status/antigravity-*.json` file (or hook stdin) the next time Antigravity's quota trips, and tell me the real field values if this doesn't catch it.

### 2026-08-09 - Claude quota 429 backoff and notch invisible-text fix
- **Developer label:** Claude quota 429 backoff and notch invisible-text fix
- **Agent label:** Claude: rate-limit backoff for oauth/usage; force dark appearance on the notch window; stop routing hosted content through NSGlassEffectView's private contentView blend
- **Changes:**
  - Added `ClaudeQuotaBackoff` actor in `ClaudeQuotaClient.swift`: on a 429 from `oauth/usage`, cache a cooldown (from `Retry-After` if present, else 5 minutes, floor 60s) and short-circuit `fetchLimits` until it passes, instead of retrying immediately on the next auto or manual refresh
  - `LLMUsageManager.refreshAll`'s network-provider throttle previously let `force`/`interactive` skip the 60s cooldown entirely (every Usage-tab open, refresh tap, or "Allow keychain access…" retry fired an uncapped request); added a 10s floor for those instead of zero
  - Root cause of the invisible notch text, per direct user report (black letters on the notch's black background, not a pure-opacity issue): nothing in the codebase ever pinned dark appearance — no `.preferredColorScheme`, no `NSAppearance`, no per-window `.appearance` — anywhere. `KannuWindow` (the notch panel) inherited whatever the *system* light/dark setting was, so `.secondary`/`.primary` text resolved near-black in Light Mode while the notch's background is hardcoded dark. Fixed by setting `appearance = NSAppearance(named: .darkAqua)` on `KannuWindow` at init, so notch text always resolves correctly regardless of system appearance
  - Two earlier, narrower attempts at this same bug are kept as harmless robustness improvements, not the actual fix: `LiquidGlassContainerView.configureBackdropLayers` now retries (bounded, 20 attempts) when it finds zero `CABackdropLayer`s instead of giving up silently, and forces a redraw when correcting a `windowServerAware` flip; separately, the hosting view is now added as a plain sibling subview on top of the glass instead of via the glass's private `contentView` key, avoiding an undocumented blend on hosted content; set `hosting.sizingOptions = []` so that sibling hosting view cannot compete with the window root for Auto Layout sizing (prevents Update-Constraints-in-Window / `NSGenericException` crashes)
  - `Localizable.xcstrings`: Usage-tab provider help text now mentions Claude's macOS keychain item (`Claude Code-credentials`) and the one-time approval prompt needed before quota can load
  - **Awaiting live confirmation on device that the appearance fix resolves the reported black-text bug.**

### 2026-08-09 - Antigravity usage card and unavailable provider chip in LLM usage panel
- **Developer label:** Antigravity usage card and unavailable provider chip in LLM usage panel
- **Agent label:** Gemini: Add AntigravityUsageProvider; show errored providers as hoverable unavailable chip
- **Changes:**
  - Add `ProviderID.antigravity` and `enableAntigravityProvider` Defaults key in `UsageProvider.swift` / `Constants.swift`.
  - Add `AntigravityUsageProvider` reading hook status files from `~/.kannu/agent-status/antigravity-*.json` to show session count and last-active timestamp; mark it `isLocalFileProvider` so `LLMUsageManager.refreshAll` refreshes it on every panel open without the shared 60s network throttle.
  - Auto-detect Antigravity on first launch via `~/.gemini/antigravity-ide` directory (independent of existing `llmProviderDefaultsConfigured` flag, via `antigravityProviderDefaultsConfigured`).
  - Show Antigravity as a full card in the usage panel (`antigravitySessionInfo` in `NotchLLMUsageView.swift`) instead of token/cost columns.
  - Providers with API errors (e.g. Codex HTTP 401) are shown as a dimmed "Unavailable" chip inline with active cards; hovering reveals the full error message with orange border highlight. (Later removed under "Drop Unavailable chips from the Usage tab" above.)
  - Add `antigravity` case to `AgentProviderIconView.init(providerID:)`.

### 2026-08-09 - Fix green traffic light lingering during idle time after agent completion
- **Developer label:** Fix green traffic light lingering during idle time after agent completion
- **Agent label:** Reduce runningStaleSeconds and activeStaleMs timeouts from 6 minutes to 15 seconds
- **Changes:**
  - Update `postToolUse`, `postToolUseFailure`, `PostToolUse`, and `PostInvocation` event mappings in `AgentHookInstaller.swift` from `executing` to `thinking`.
  - Reduce `runningStaleSeconds` in `AgentTrafficLightMapper.map` from 360 to 15 seconds so non-generating sessions do not report false active thinking during idle time.
  - Reduce `activeStaleMs` default in `AgentTrafficLightMapper.resolveHookState` from 360,000ms (6 minutes) to 15,000ms (15 seconds) so idle hook sessions turn off green light once completed.

### 2026-08-09 - Antigravity agent status provider
- **Developer label:** Antigravity agent status provider
- **Agent label:** Antigravity IDE & CLI status hook support
- **Changes:**
  - Add Google Antigravity (IDE & CLI) support to `AgentHookProvider` with matcher-group hook installation into `~/.gemini/antigravity-ide/hooks.json` (also mirrored to `~/.gemini/config/hooks.json` and `~/.gemini/hooks.json`).
  - Extend `kannu-agent-status.sh` / embedded installer script to parse Antigravity invocation and workspace payload events (`PreInvocation`, `workspacePaths`, etc.).
  - Render running provider icon and provider name label (`Antigravity`, `Cursor`, `Claude`, `Codex`) inside `AgentTrafficLightIndicator`; add `antigravity` to `AgentSessionStatus.providerLabel`.
  - Add Antigravity provider detection to `NotchAgentStatusView` empty-state cards and `AgentProviderIconView` (bundle IDs / app paths / `atom` SF Symbol).
  - `KannuApp.swift`: include `(.antigravity, ".gemini")` in the on-launch provider-directory presence scan used for hook setup.
  - `ReadMe.md`: mention Google Antigravity alongside Cursor, Copilot, Codex, and Claude in the agent-status blurb.

### 2026-08-06 - Fix release version drift
- **Developer label:** Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION past the shipped tags
- **Agent label:** Existing installs can see a new release as newer again
- **Changes:**
  - `MARKETING_VERSION` 1.0.0 → 1.2.0 and `CURRENT_PROJECT_VERSION` 1 → 2 in both Debug and Release configs. Tags `v1.0.0` and `v1.1.0` both existed while the project file still said `1.0.0 (1)`, so the build tagged v1.1.0 reported itself as 1.0.0
  - Sparkle compares `CFBundleVersion` / `CFBundleShortVersionString` against the appcast, so any release cut from the old numbers would not have been seen as newer by an installed copy — auto-update was silently dead even after the appcast signing fix
  - The project file is the sole source of truth: the release workflow and scripts contain no `agvtool` or version handling, and `Info.plist` has no version keys (`GENERATE_INFOPLIST_FILE` synthesises them)

### 2026-08-06 - Agent state accuracy, resize crash fix, per-display notch settings
- **Developer label:** AppKit re-entrancy crash, Claude/Cursor traffic-light correctness, per-display display settings
- **Agent label:** Red means done, yellow means it needs you, and the notch behaves per display
- **Changes:**
  - Fixed random `SIGABRT` on window resize: `NSHostingView.sizingOptions` was unset so SwiftUI resized the window from inside the window's own layout pass. Set `sizingOptions = []`, added a re-entrancy guard with coalesced pending resize dispatched via `RunLoop.main.perform`, and split `setFrame(display: false)` from a deferred `displayIfNeeded()`. Removed the dead `animated` parameter and stubbed `shouldAnimateResize`
  - Expanded Claude hook coverage to matcher-scoped groups: `Notification/agent_completed` → stopped (the first real "it's done" signal), `Notification/permission_prompt|idle_prompt|agent_needs_input` → awaiting input, `PreToolUse` matched on `ExitPlanMode|AskUserQuestion` → awaiting input (plan-approval waits now show yellow), plus `StopFailure` and `SessionEnd`. Hook script v24
  - Claude runs matcher groups in parallel with no ordering guarantee, so gated-tool detection is covered three ways: the matcher group, tool-name detection in the generic `PreToolUse` group, and a no-downgrade tiebreak on same-event writes within 2s
  - Relaxed `checkInstalled(.claude)` to a core event subset and keyed the script-version migration on script-file existence — otherwise growing the hook table would make existing installs report "not installed" and skip their own upgrade
  - Passive Claude detection now reads the transcript tail instead of file mtime: an assistant `tool_use` with no result means a tool is in flight (green), `stop_reason` of `end_turn`/`stop_sequence` means the turn finished (red). A long tool no longer reads as idle, and Claude reaches red without hooks installed. Passive never reports yellow — that stays hook-only, since a permission dialog isn't visible from disk
  - Hook sessions in an active state no longer age out while the process is provably alive: a tool running past the 6-minute staleness threshold kept dimming the session mid-work
  - Fixed Cursor showing yellow while working: `beforeShellExecution` fires for auto-approved commands so it no longer means "waiting", the sticky-yellow latch is narrowed to `afterAgentThought` and preserves its original timestamp (refreshing it defeated the 5-minute escape), a live `generating` status now beats a stale transcript approval flag, and the transcript walk terminates on `turn_ended` or a `tool_result`
  - New installs on Macs without a notch default to Dynamic Island, hidden until hovered. Notched Macs are unchanged
  - Notch detection now asks the built-in display via `CGDisplayIsBuiltin` rather than `NSScreen.main` — setting up while docked misclassified a notched MacBook. The answer is cached and re-resolved on display changes, so a clamshell setup corrects itself when the lid opens. No hardcoded model list
  - Added per-display overrides for notch style and hide-until-hover, keyed by screen name and falling back to the global settings. Notched built-in displays are omitted from the list since their shape is fixed by hardware
  - Hovering the hidden island no longer leaves it out after the pointer leaves; agent activity reveals it for 3s (was 6s), with a 2s heartbeat while a run is in progress so a long silent tool keeps the light lit
  - Fixed `readTrailingLines` returning nil for files smaller than its read window, which silently sent callers to a fallback that read the start of the transcript

### 2026-07-31 - Fix Sparkle CI appcast signing
- **Developer label:** Fix Sparkle update export in release workflow
- **Agent label:** Pass EdDSA key file to generate_appcast on CI
- **Changes:**
  - Fixed `scripts/export-sparkle-update.sh` so `generate_appcast` receives `--ed-key-file` (CI has no Sparkle Keychain account, which caused "lack of private EdDSA key")
  - Kept the private key file until after appcast generation instead of deleting it after `sign_update`
  - Corrected existing-feed reuse: copy `Updates/appcast.xml` into the archives staging dir (was incorrectly using `--link`)

### 2026-07-20 - Usage limits, tier badges, and reset time formatting
- **Developer label:** Account tier display, improved reset-time UI, hidden pricing estimates for subscription models
- **Agent label:** Show plan tier (Pro/Max) per provider, format resets as days/hours or hours/minutes, hide token-pricing for Claude/Codex
- **Changes:**
  - Added `accountTier` field to usage snapshots; wired from Claude credential (subscriptionType), Cursor API (membershipType), Codex JWT (chatgpt_plan_type) — renders as capsule badge next to provider name
  - Updated `resetsIn()` formatting: ≥69h → "Xd Yh", 1–69h → "Xh Ym", <1h → "Xm Ys" — consistent across all provider gauges (Session/Week limits)
  - Claude and Codex now hide pricing-table cost estimates and show only actual billed spend (via `billedCostOnly` flag), matching Cursor's behavior; token counts always displayed
  - Idle sessions (SessionStart → "idle" state) now show as dim cards instead of green-lit "running" cards

### 2026-07-20 - Fix chat name regressions for all agents
- **Developer label:** Chat name self-comparison bug fix for Cursor/Claude/Codex
- **Agent label:** Restore AI-generated and transcript-derived session titles
- **Changes:**
  - Fixed `resolveHookProviderChatName` (Claude/Codex): log-derived titles (ai-title) were compared against themselves in reliability checks and always rejected; now trusted directly with only tool-name heuristic
  - Fixed `resolveCursorChatName` (Cursor): transcript titles were compared against themselves and always rejected; now handled separately and trusted directly
  - Both fixes were dormant bugs exposed when hooks were auto-installed, routing sessions through the hook-driven merge pipeline for the first time

### 2026-07-20 - Tab retention, native HUD suppression fix, battery easter egg
- **Developer label:** Always-on tab retention, brightness HUD suppression fix, 69% battery easter egg
- **Agent label:** Fixed tab-restore race with Defaults publishers, wired up missing brightness OSD suppression, added subtle battery percentage easter egg
- **Changes:**
  - Notch tab selection now always persists across app restarts (removed the "Remember last tab" toggle; behavior is unconditional)
  - Fixed a race in `KannuViewCoordinator.init()` where initial-fire `Defaults.publisher` subscriptions (stats/timer/minimalistic UI gating) could reset `currentView` to `.home` after the tab was restored, depending on which tab was last selected — restore is now deferred to run after those resets
  - Auto-focusing the Agent tab on notch hover-open now only happens when the current tab is Home, so it no longer overrides a deliberately selected tab
  - Fixed missing native OSD suppression for brightness: `SystemOSDManager.suppressNativeOSDNow()` was called for volume/mute but never for brightness key presses or `sendBrightnessNotification`, so the native brightness HUD could win the race against Kannu's notch HUD
  - Added a subtle easter egg: battery percentage at exactly 69% gets a quiet golden shimmer with a "nice." tooltip, and the battery detail popup shows "nice." next to the percentage

### 2026-07-18 - Glass UI, tab hover, approval detection
- **Developer label:** Frosted glass UI, hover-based tabs, AI chat title detection, provider auto-detection
- **Agent label:** Enhanced visual polish with glass effects, responsive tab switching, smart session naming
- **Changes:**
  - NotchAgentStatusView: ultraThinMaterial frosted glass backgrounds for agent cards with tint overlay and hairline borders; red-light blink animation (5s smooth sine pulse) with neon color palette
  - TabSelectionView/TabButton: hover-based tab switching (80ms debounce to prevent accidental flips); tab selection indicator is now a circle matching icon size with ultraThinMaterial finish
  - AgentSessionLogParser: displayChatName() now searches trailing JSONL bytes for ai-title records to show AI-generated chat labels instead of raw prompts
  - LLMUsageManager: auto-detect installed providers on first launch (Claude `~/.claude/projects`, Cursor `state.vscdb`, Codex `~/.codex/sessions`) and enable only those present; stores flag to run once
  - Empty state in Agent tab shows fun message + provider install strip (visible only when no sessions exist)

### 2026-07-18 - Indicator timing fixes and auto-install hooks
- **Developer label:** Indicator timing granularity and hook auto-install
- **Agent label:** Second-level control over indicator persistence, automatic hook setup
- **Changes:**
  - Changed indicator timing from minutes to seconds: agentStoppedCollapseMinutes → agentStoppedCollapseSeconds (default 5s), agentInactiveDisplayMinutes → agentInactiveDisplaySeconds (default 5s)
  - Fixed unit multipliers in state mapper to use direct seconds instead of `×60` scaling
  - Updated Settings time pickers with second-granular options: Hide indicator (3s–5min), Show dim light (Off/5s–2min)
  - Auto-install hooks on first launch for detected providers (Claude, Cursor, Codex); gated by agentHooksAutoInstallAttempted flag
  - Red light now hides after 5 seconds instead of persisting for minutes; state transitions are instant with hook events active

### 2026-07-17 - v1.0.0 release
- **Developer label:** v1.0.0 release
- **Agent label:** Initial public release version bump
- **Changes:**
  - Set `MARKETING_VERSION` to `1.0.0` and `CURRENT_PROJECT_VERSION` to `1` in `Kannu.xcodeproj/project.pbxproj`.
  - Updated release examples in `scripts/RELEASE.md` for the `v1.0.0` tag.

### 2026-07-17 - Automate CI releases
- **Developer label:** Automate CI releases
- **Agent label:** Tag-triggered signed notarized release pipeline
- **Changes:**
  - Rewrote [`.github/workflows/release.yml`](.github/workflows/release.yml) to validate secrets, archive/export with Developer ID, notarize the DMG, and publish on `v*` tag push only.
  - Added [`ExportOptions.plist`](ExportOptions.plist) and [`scripts/notarize-dmg.sh`](scripts/notarize-dmg.sh) for CI notarization.
  - Expanded [`scripts/RELEASE.md`](scripts/RELEASE.md) with GitHub secrets setup and automated release instructions.

### 2026-07-17 - Manual GitHub release
- **Developer label:** Manual GitHub release
- **Agent label:** Manual release script and docs
- **Changes:**
  - Bumped Release version to `2.2.1` (build `13`) in `Kannu.xcodeproj/project.pbxproj`.
  - Added `scripts/manual-release.sh` to build a versioned DMG, Sparkle-sign it, update `Updates/appcast.xml`, and optionally publish via `gh`.
  - Added `scripts/RELEASE.md` and linked it from `ReadMe.md`.

### 2026-07-17 - Claude detection fixes, glass UI, color picker, SVG skin support
- **Developer label:** Claude detection fixes, glass UI, color picker, SVG skin support
- **Agent label:** Claude passive session detection, frosted glass notch, wheel color picker, SVG skins
- **Changes:**
  - Fixed Claude agent detection: NSNumber int64 cast, stale-check bypass for live processes, PID-reuse guard via sysctl start-time comparison, force isVisible=true for live sessions waiting for user input
  - Agent tab empty state with fun message and provider install strip; strip hidden when any session exists
  - Settings > Agent Status: added Detected Editors row showing Cursor/Claude Code/Codex install status
  - Tab switching on hover with 80ms debounce; frosted glass capsule (ultraThinMaterial) replacing flat fill; removed hidden matchedGeometry capsule that caused blink on tab change
  - Agent status cards updated to ultraThinMaterial frosted glass with hairline borders
  - Color picker swatch: replaced two-step swatch→popover→NSColorPanel with direct NSColorWell (one click opens wheel); swatch shrunk to 22×14
  - Notch skin importer: added SVG support in file picker and allowed extensions; vector files skip pixel-size validation

### 2026-07-17 - Brightness notch indicator fix
- **Developer label:** Brightness indicator is not working in notch
- **Agent label:** Brightness notch HUD passive detection restore
- **Changes:**
  - Restored always-on brightness polling in `Kannu/managers/SystemMediaControllers.swift` with key-press-only notch HUD: intercepted keys, observe-only key taps, and discrete step heuristics; auto-brightness updates baseline silently.
  - Added brightness key observe-only handling in `Kannu/managers/MediaKeyInterceptor.swift` and `Kannu/managers/SystemChangesObserver.swift` so key presses are tagged before macOS applies the change.
  - Fixed standard (non-inline) notch HUD drag handling for brightness/volume/backlight in `Kannu/ContentView.swift`.

### 2026-07-17 - Sparkle auto update
- **Developer label:** Sparkle auto update
- **Agent label:** Sparkle auto update integration
- **Changes:**
  - Added `Kannu/managers/SparkleUpdaterController.swift` to start Sparkle in Release builds with bundle ID `com.kannu.app`.
  - Wired automatic update checks and manual **Check for Updates…** entry points in the menu bar extra, app menu, and Settings → About.
  - Added Sparkle feed keys to `Kannu/Info.plist` and an initial `appcast.xml` hosted from `main`.
  - Extended `.github/workflows/release.yml` and `scripts/export-sparkle-update.sh` to publish signed `Kannu.zip` update archives and refresh the appcast on release.

### 2026-07-17 - Sparkle release workflow fix
- **Developer label:** Sparkle auto update
- **Agent label:** Release workflow secrets guard fix
- **Changes:**
  - Fixed `.github/workflows/release.yml` so Apple certificate import skips inside the step script instead of using `secrets` in a step `if` (unsupported by GitHub Actions).

### 2026-07-17 - Atoll-style Sparkle appcast layout
- **Developer label:** Sparkle auto update
- **Agent label:** Atoll-style Updates appcast layout
- **Changes:**
  - Moved the Sparkle feed to `Updates/appcast.xml` (matching [Atoll](https://github.com/Ebullioscopic/Atoll/tree/main/Updates)) and updated `SUFeedURL` in `Kannu/Info.plist`.
  - Added `SUEnableDownloaderService` and `SUEnableInstallerLauncherService` Sparkle keys like Atoll.
  - Switched `scripts/export-sparkle-update.sh` and release CI from `Kannu.zip` to versioned DMG enclosures (`Kannu.<version>.dmg`).

### 2026-07-12 - Fix brightness and native OSD regression
- **Developer label:** Fix brightness and native OSD regression
- **Agent label:** Non-blocking OSD suppress and brightness path restore
- **Changes:**
  - Restored brightness handling in `Kannu/managers/SystemChangesObserver.swift` by removing `suppressNativeOSDNow()` from the brightness key handler and `sendBrightnessNotification`, which had been blocking the main-thread brightness animation timer.
  - Made `SystemOSDManager.suppressNativeOSDNow()` dispatch `SIGSTOP` on a dedicated queue in `Kannu/managers/SystemOSDManager.swift` so volume suppress never blocks the event tap or main thread.
  - Added Accessibility and media-key tap failure logging in `SystemChangesObserver.startObserving()` when native volume/brightness indicators are expected to show through.

### 2026-07-12 - Hide native volume brightness OSD
- **Developer label:** Hide native volume brightness OSD
- **Agent label:** Synchronous OSDUIHelper suppress before media-key writes
- **Changes:**
  - Made `SystemOSDManager.suppressNativeOSDNow()` run `SIGSTOP` inline in `Kannu/managers/SystemOSDManager.swift` instead of `Task.detached`, so suppression can beat CoreAudio waking the native bezel.
  - Called `suppressNativeOSDNow()` before volume, mute, and brightness media-key adjusts in `Kannu/managers/SystemChangesObserver.swift`, and at the start of `sendBrightnessNotification` for non-key brightness changes.

### 2026-07-12 - Notch fill color picker fix
- **Developer label:** Notch fill color picker fix
- **Agent label:** Notch fill popover picker
- **Changes:**
  - Replaced `NotchFillColorPickerRow` `NSColorPanel` usage in `Kannu/components/Settings/SettingsView.swift` with `SettingsColorPickerRow` popover so the notch fill picker no longer traps inside the Settings window.

### 2026-07-12 - Fix Recent Chat Names and LLM Usage Pricing
- **Developer label:** Fix Recent Chat Names and LLM Usage Pricing
- **Agent label:** Agent status, chat titles, and usage pricing overhaul
- **Changes:**
  - Updated `scripts/kannu-agent-status.sh`, `Kannu/managers/AgentStatus/AgentHookInstaller.swift`, and added `scripts/install-cursor-hooks.sh` to version `KANNU_HOOK_SCRIPT_VERSION=23`, with Cursor Shell Run approval (`afterAgentResponse`, `beforeShellExecution`), `afterAgentThought` thinking updates, `agentId`-first status filenames, title-bearing-event-only name ingestion, sticky-yellow fixes, and Claude/Codex/VS Code hook parity.
  - Added `Kannu/managers/AgentStatus/CursorGlassAgentStore.swift` and `Kannu/managers/AgentStatus/AgentSessionLogParser.swift`; updated `CursorComposerStore.swift`, `CursorTranscriptParser.swift`, `CursorAgentStatusMonitor.swift`, `AgentApprovalGatedTools.swift`, and `AgentTrafficLightState.swift` to resolve real Cursor sidebar names (`cursorDiskKV` composerData), reject plan-file/assistant-prose/prompt fallbacks, prune orphan hook files, paint yellow for Shell Run waits, broaden simulation-session filtering, and enrich Codex/Claude sessions from JSONL logs.
  - Updated `Kannu/components/AgentStatus/NotchAgentStatusView.swift` for continuous `MM:SS` run timers, state-first session dedup, and reliably titled primary-card tie-breaking; updated `AgentProviderIconView.swift` and `SettingsView.swift` for Claude Code hook provider labels.
  - Updated `Kannu/KannuViewCoordinator.swift` and `Kannu/components/Tabs/TabSelectionView.swift` to keep the Stats tab aligned with stats-feature and per-graph visibility settings.
  - Updated `Kannu/managers/LLMUsage/ModelPricingManager.swift`, `ModelPricing.swift`, `pricing.json`, and `.github/workflows/update-pricing.yml` to normalize model IDs, guard sparse remote pricing overrides, and expand priced-model coverage.
  - Updated `CursorUsageEventsClient.swift`, `CursorUsageProvider.swift`, `Quota/CursorAPIHelpers.swift`, `Quota/CursorQuotaClient.swift`, `UsageProvider.swift`, and `NotchLLMUsageView.swift` to fix inflated on-demand spend (USAGE_BASED only), expose billing-cycle on-demand USD, discount cache-read fallback pricing, and show on-demand spend when quota gauges are visible.

### 2026-07-11 - Agent stats and recent chats default instead of CPU metrics
- **Developer label:** Agent stats and recent chats default instead of CPU metrics
- **Agent label:** Agent defaults over CPU stats
- **Changes:**
  - Set `showCpuGraph`, `showMemoryGraph`, and `showGpuGraph` defaults to `false` in `Kannu/models/Constants.swift`.
  - Updated Developer onboarding profile in `Kannu/components/Onboarding/ProfileSelectionView.swift` to keep `enableStatsFeature` off while `enableAgentStatusFeature` stays on.

### 2026-07-11 - Display on all screens on by default
- **Developer label:** Display on all screens on by default
- **Agent label:** Show on all displays default on
- **Changes:**
  - Set `showOnAllDisplays` default to `true` in `Kannu/models/Constants.swift`.

### 2026-07-10 - Now Playing Default + Apple-Style Logo Corners
- **Developer label:** Now Playing Default + Apple-Style Logo Corners
- **Agent label:** Implement Now Playing default and startup logo cornering
- **Changes:**
  - Updated `Kannu/models/Constants.swift` to default `mediaController` to `.nowPlaying` for new installs.
  - Added one-time migration `migrateMediaControllerToNowPlaying()` and migration flag key so existing `.appleMusic` users move to `.nowPlaying`.
  - Wired `Defaults.Keys.migrateMediaControllerToNowPlaying()` into launch migrations in `Kannu/KannuApp.swift`.
  - Updated `Kannu/components/Onboarding/WelcomeView.swift` to clip the startup `logo2` image with Apple-style continuous rounded corners.

### 2026-07-10 - Show focus as brief toast enabled by default
- **Developer label:** Show focus as brief toast enabled by default
- **Agent label:** Focus brief toast default on
- **Changes:**
  - Set `focusIndicatorNonPersistent` default to `true` in `Kannu/models/Constants.swift`.

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
