# Changelog

Each commit must add one new entry under `## [Unreleased]` before committing.

## [Unreleased]

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
### 2026-08-20 - Project-level ART engineering framework
- **Developer label:** Add CLAUDE.md with the ART framework and Kannu engineering standards
- **Agent label:** Claude Code sessions in this repo now start from a shared persona, architecture principles, and repo facts
- **Changes:**
  - New repo-root `CLAUDE.md`: the ART breakdown ceremony (Act as / Request / Terms / Relevant skills, shown before any work), skill-loading discipline with explicit honesty clauses (never invent an unlisted skill, zero skills is valid, failed loads are stated), the Senior macOS Swift Architect persona, product context, architecture principles, and audit/UI/debugging/security/testing rules
  - Ships the executable repo knowledge sessions kept rediscovering: build/run/verify commands (verification vs runnable ad-hoc builds, `open`-only launches, `/usr/bin/log` over the zsh `log` builtin), house conventions (GPL header, `Defaults` key idiom in `Constants.swift`, `String(localized:)`, the `settingsSearchIndex`/`settingsHighlight` pairing, manager singleton shape), and known traps: the building pre-commit hook with its mandatory changelog entry, the `Kannu.debug.dylib` split that breaks binary greps, the stale-build-database false success, eager TCC touches in `AppDelegate.init` freezing launch, `Defaults.publisher`'s initial-fire behaviour, and the embedded-vs-mirrored hook script pairing

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
