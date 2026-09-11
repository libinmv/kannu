# Changelog

Each commit must add one new entry under `## [Unreleased]` before committing.

## [Unreleased]

### 2026-09-11 - Timer, Notes, Clipboard, Screen Assistant, Shelf, Downloads and Shortcuts in the System Settings layout
- **Developer label:** "the settings should be enginered like apple does settings" (scope picked: "Rework every tab")
- **Agent label:** Same row rules on the remaining productivity tabs, plus four visible bugs fixed
- **Changes:**
  - Timer: the Clock-mirroring and display-mode explanations (tooltips) and the lock-screen
    surface notes are descriptions; the custom duration is a "Default Custom Timer" row plus
    Hours/Minutes/Seconds rows (value and stepper trailing); Restore Defaults and Add Preset sit
    on the trailing side; the sound row is one row with Reset and Choose File trailing. The
    stepper side effects moved to the Form so a row that is not built yet cannot miss them.
  - Timer sound: the row read `customTimerSoundPath` straight from UserDefaults, so after Choose
    File or Reset it kept showing the old file until something else redrew the tab; it is now
    `@AppStorage` and updates at once (same key; the timer still reads it the same way).
  - Downloads: "Download indicator style" was hard-coded white and invisible in light mode.
  - Clipboard and Shortcuts said the clipboard shortcut is Cmd+Shift+V; the default is ⇧⌘C and it
    is user-set. The Clipboard and Screen Assistant footers now show the actual shortcut; the
    Shortcuts rows drop the stale defaults (the recorder shows the real one).
  - Shortcuts: five one-row groups with right-aligned footers become one group of recorder rows,
    each explained under its (translated) title; the disabled placeholder group is gone.
  - Clipboard and Screen Assistant: labelled pickers instead of text plus an unlabelled picker;
    value rows as `LabeledContent`; the permanent Clear actions sit on the trailing side and keep
    their red text; clipboard previews can be selected.
  - Notes: Sync Now is a trailing button beside "Last synced" instead of a full-width button;
    Shelf: the Quick Share explanation sits under its picker; every footer on these tabs is
    selectable and left-aligned.
  - Keys, bindings, side effects and highlight ids unchanged (inventory test). DEBUG harness: a
    `shortcutRows` board for the recorder rows (shown only once global shortcuts are on).

### 2026-09-11 - Controls is one Form; Battery in the System Settings layout
- **Developer label:** "the settings should be enginered like apple does settings" (scope picked: "Rework every tab")
- **Agent label:** Rebuild the Controls tab as a single scrolling Form; Battery rows, sliders and test buttons
- **Changes:**
  - Controls stacked two Forms (the selected style's settings, then step size and display
    integrations) under a fixed row of style cards: two regions scrolled separately, a footer was
    clipped, and the fourth card ran off the window edge. Now one Form: the cards are the first
    group (flexible width, all four fit), then the style's groups, then Step size and DDC.
  - `HUD`, `CustomOSDSettings` and `ExternalDisplayIntegrationsSection` now emit sections. Their
    side effects moved to the Controls Form because rows in a lazy Form cannot host them
    reliably, keyed by the selected card exactly as before: Dynamic Island — Accessibility
    revoked turns the system HUD off, granted starts the media-key tap; Custom OSD — revoked turns
    the OSD off and hides its windows. Turning the OSD off hides its windows from any card, the
    macOS 26 material fallbacks run when the tab appears, and switching cards refreshes the
    Accessibility status (it used to on each sub-view's appear).
  - Keyboard-backlight, audio-feedback and DDC explanations (tooltips or rows of their own) are
    descriptions; steppers show "6%" beside the stepper; size sliders share `dimensionSlider`;
    Reset to Default sits on the trailing side. The DDC status description showed its Markdown
    links as raw brackets; it now renders them.
  - Battery: durations and thresholds use the new shared `SettingsSliderRow` (title leading,
    slider and value trailing); the style explanations sit under their pickers; the three test
    buttons are "Charging HUD / Low battery HUD / Fully charged HUD" rows with Test on the
    trailing side. Each registers a highlight id, so the three "Test … HUD" search entries,
    which opened the tab and scrolled nowhere, now land on their row (inventory test: every
    entry names a row; 249 registrations).
  - DEBUG harness: a `controlStyles` board renders the Custom OSD, Vertical Bar and Circular
    groups without changing the selected card.

### 2026-09-11 - Media, Live Activities, Lock Screen and Devices in the System Settings layout
- **Developer label:** "the settings should be enginered like apple does settings" (scope picked: "Rework every tab")
- **Agent label:** State notes become footers or descriptions, tooltips become visible text, packed rows split, one slider pattern
- **Changes:**
  - Media: the Dynamic Island and customizable-controls notes are footers instead of rows; the
    Change Media Output, floating controls and live canvas explanations that only lived in
    tooltips are visible, selectable descriptions; the three fullscreen-artwork toggles that
    shared one row are three rows; parallax intensity and the inactivity timeout show their
    value beside the control; the fullscreen hide option is a radio group under its own
    header, so "Hide only when NowPlaying app is in fullscreen" no longer truncates.
  - Live Activities: the Focus label and brief-toast explanations (tooltips) are descriptions;
    every footer is selectable.
  - Lock Screen: material, glass mode, timer surface, timer glass and AQI notes sit under the
    control they explain; Preview and Copy Latest Crash Report sit on the trailing side; the
    fullscreen toggles are separate rows; Positioning lists the three offsets as rows (value and
    Reset trailing, Reset disabled at zero) and moves the width sliders to their own
    **Widget Width** group with both resets on the trailing side — the empty Divider row and the
    right-aligned help text are gone.
  - Devices: footers selectable; the HUD icon style title reads like other row titles.
  - Glass-variant sliders (Appearance and Lock Screen) share `variantSliderControl`: title on the
    leading side, slider and "v11" trailing.
  - Keys, bindings, side effects, disabled and dimmed conditions, the Media → Lock Screen mirror
    and highlight ids are unchanged (inventory test).

### 2026-09-11 - General and Appearance in the System Settings layout; a mislabelled media toggle
- **Developer label:** "the settings should be enginered like apple does settings" (scope picked: "Rework every tab")
- **Agent label:** Captions under titles, composite rows split into rows, buttons trailing, footers left-aligned and selectable
- **Changes:**
  - General: hover duration, external display style and always-show carry their explanations under
    the title; the slider sits at a fixed width so its explanation is not squeezed; Launch at
    login's approval hint is a row with Open Login Items on the trailing side; the gesture footer
    is no longer right-aligned. Per-display overrides get one group per display (header with a
    Built-in badge, Reset on the trailing side) instead of one packed row per display.
  - Appearance: Notch Width is three rows plus "Recommended width" with Reset on the trailing side
    and the explanation as the footer (the Divider inside the row is gone); both width sliders
    show their value beside the slider, so "Closed notch / pill width" no longer wraps; notch
    fill colour and lock-screen glass captions sit under their titles; notch skin and app icon
    split into the gallery, a trailing button row (Remove selected, then the primary Upload/Add)
    and a footer; the app-icon thumbnail is clipped to its rounded card (square corners showed).
  - The Media toggle for `playerColorTinting` was labelled "Enable colored spectograms", nearly
    the same as the spectrogram toggle above it; it now reads "Tint player controls with the
    album art color" (setting unchanged; the five translations of the old label translated the
    wrong words and now fall back to English).
  - `SettingsColorPickerRow` gains an optional description; the row components gain a
    state-dependent description. DEBUG harness: a `displays` board for the per-display groups
    (a lone MacBook lists none). Keys, bindings, side effects and highlight ids unchanged.

### 2026-09-11 - Agents and Usage tabs in the System Settings layout; the Agents tab stops re-rendering on every rescan
- **Developer label:** "the settings should be enginered like apple does settings" (scope picked: "Rework every tab")
- **Agent label:** Descriptions under their titles, labelled pickers, trailing buttons, selectable footers; decouple the preview from the monitor
- **Changes:**
  - Agents: every caption that sat in a row of its own now sits under its setting's title
    (terminal tab, traffic light style, smart caffeinate, red light, wait reminder, provider);
    the three indicator pickers are labelled menus instead of a text plus an unlabelled picker
    (the first no longer wraps onto two lines); the state colours read as title and meaning with
    the swatch trailing; Reset Colors, the test notification and every footer follow the same
    rules; Detected Editors is a grid, so "Claude Code" and "Claude Desktop" no longer wrap.
  - Mobile notifications split into where pushes go (provider, address or keys, test push) and
    **Notify about** (inactive, wait reminder, findings, usage limit).
  - The Agents tab observed `CursorAgentStatusMonitor` only for the style preview, so the whole
    tab re-rendered on every rescan while agents ran. The preview now observes the monitor on
    its own. The editor and hook-tool file checks run when the tab appears instead of on every
    render.
  - Usage: footers no longer right-aligned, both alert captions under their titles.
  - Titles, keys, bindings, side effects, disabled and dimmed conditions and highlight ids are
    unchanged (inventory test). DEBUG harness: a `notifications` board for the rows that show only
    once pushes are on.

### 2026-09-11 - Agents › security, laid out like System Settings: compact findings first
- **Developer label:** "fix the allignment, spacing and padding of settings items, especially these nwe findings sections, dont leave area with lot of empty spacing in rach finfings window"
- **Agent label:** Split the one long security section into four groups and switch findings to the compact row
- **Changes:**
  - One section held the ADR connection, Kannu's own checks, ADR Detection and the findings,
    with `Divider()`s that drew as empty rows and every caption in a row of its own. Now:
    **Security findings** (the list first, then the high-severity alert picker with its
    explanation under the title, and "Show acknowledged and snoozed again" on the trailing side;
    the header keeps the deep-link id), **ADR Discovery** (tools with a status dot, snapshot
    folder, last snapshot, scans, policy file), **Kannu's own checks** (five switches, each with
    its description under the title) and **Session analysis**, which once turned on adds
    **Analysis models**, **Analysis context and limits** and **Recent analyses**.
  - Findings use the compact `SecurityFindingRow` (Details opens the rest in place; Acknowledge,
    Snooze 24h and Reveal in Finder move into the "…" menu). Recent analyses get the same
    trailing Copy for agent and "…" (Reveal Report in Finder, Forget).
  - Every description, footer, path, status and error in these sections can be selected and
    copied. Setting titles, keys, bindings, side effects, disabled conditions, the consent alert
    and all highlight ids are unchanged (the inventory test pins them).
  - The ADR key rows no longer read the keychain on every render (the tab re-renders on each
    monitor publish): which keys are stored is read when the tab appears and after Save/Remove.
  - The "No findings yet" message no longer points at a folder above; the scan row is titled
    "Scan this Mac"; the old footer is split between the sections it describes.
  - `docs/ADR.md` paths updated (ADR Discovery, Session analysis) and the finding-row
    description rewritten. DEBUG harness: a `detection` board shows the rows that appear only
    once analysis is on, without turning it on.

### 2026-09-11 - Settings building blocks in the System Settings layout; two search entries that scrolled nowhere
- **Developer label:** "fix the allignment, spacing and padding of settings items, especially these nwe findings sections, dont leave area with lot of empty spacing in rach finfings window / many text in normal areas are also not copypastable, the settings should be enginered like apple does settings"
- **Agent label:** Shared Settings row components and a compact finding row, checked on a snapshot board; highlight-id inventory test
- **Changes:**
  - New `SettingsComponents.swift`: `SettingsRow` (title and description leading, control
    trailing; the control keeps its own label for VoiceOver and is drawn as a switch, since a
    Toggle nested in `LabeledContent` falls back to a checkbox), `SettingsRowLabel`,
    `SettingsFooter`, `SettingsActionRow` (buttons on the trailing side, never hanging on the
    left), `SettingsMoreMenu` ("…"), `SettingsValueText`, `SettingsStatusText`,
    `SettingsErrorText` and a self-contained `CopyForAgentButton`. Descriptions, footers, values
    and statuses can be selected and copied; control labels never are (a selectable label
    swallows the control's click).
  - New `SecurityFindingRow.swift`: shield, title, severity and a two-line summary, with Copy
    for agent and a "…" menu (Acknowledge, Snooze 24h, Reveal in Finder) on the same line;
    "Details" opens the evidence, what it means and what to do in place. Not wired into the
    Agents tab yet (next commit).
  - The DEBUG snapshot harness gains a `components` board (native controls beside the
    components, enabled and disabled, finding rows collapsed and expanded; light and dark).
  - Two search entries scrolled nowhere because no row registered their id: "Enable Custom OSD"
    (now lands on the Custom OSD card) and "LocalSend Device Picker Style" (the picker never
    applied the id it was handed).
  - `SettingsPermissionCallout`'s message can be selected and copied.
  - New `SettingsHighlightInventoryTests` reads the Settings sources and pins the pairing: every
    search entry lands on a registered row of its own tab, every deep link is registered, and the
    entry and registration counts are pinned so a layout rework cannot drop a registration
    unnoticed (it caught both drifts above; verified to fail when a registration is removed).

### 2026-09-11 - One card per Claude chat: subagents fold into their parent
- **Developer label:** "did a regression happen in chat names for claude, it shows untitle chat, also 2 chats showingh, maybe duplicated"
- **Agent label:** Hook v38 parent_id plus a tested fold of subagent hook files into the parent's card
- **Changes:**
  - Cause (verified live: three `claude-<17-hex>.json` files appeared while three Explore agents
    ran): Claude Code fires a subagent's hooks with `agent_id` beside the parent's `session_id`, and
    the hook has picked `agent_id` first since v23 (a Cursor change). Each subagent became its own
    "Untitled chat" card, and its last `thinking` write could relight a finished chat green for up to
    six minutes (holding caffeinate). Not caused by the recent phases.
  - Hook script v38 (mirror and embedded copy regenerated; no backslash): for Claude and Qwen, an
    event with `agent_id` records the parent's session id as `parent_id` in the subagent's own file.
    The state machine is untouched; Cursor's `agentId` stays its own conversation; `agent_type`
    alone (a `--agent` main thread) is not a subagent.
  - New pure `AgentTrafficLightMapper.foldSubagentHookSessions` (logic target): while the parent's
    turn is open the more urgent light wins (a subagent's permission prompt turns the chat yellow;
    the parent's own progress cannot hide it; two prompts stay yellow until both are answered);
    after the turn ends a leftover subagent file changes nothing; with no parent file a stand-in
    carries the parent's id and is named from its transcript; identity, name and locators stay the
    parent's and extras ride `carryingExtras` (sightings found by a subagent belong to the chat).
    The monitor reads the validated `parent_id`, folds before names are resolved, and keeps folded
    ids out of the hooks-only retention. Files from v37 have no `parent_id` and age out as before.
  - Tests: `SubagentFoldTests` (no card of its own, yellow while open, two prompts, no relight,
    aged parent, stand-in named by the reconciler, providers never cross, aggregate unchanged over
    every open-turn combination, id validation) and six `HookScriptTests` for v38. REGRESSIONS
    entry 5 addendum.

### 2026-09-11 - Hook events no longer re-list Cursor's transcripts for nothing
- **Developer label:** "how can we optimize that" (the notch's CPU while an agent works)
- **Agent label:** Skip project-name enrichment when every session already has a project
- **Changes:**
  - Profiling a busy Claude session showed the main thread's rescan time dominated by
    `enrichProjectNamesFromTranscripts`, which listed every recent Cursor transcript folder and read
    every provider's logs on each hook event — before checking whether any session lacked a project
    name. Hook files carry their project (from cwd), so usually none do. It now returns at once when
    nothing needs a name and builds only the maps a nameless session needs. Same result, same
    tests; the work simply is not done when it cannot change anything.

### 2026-09-11 - Claude chat names hold on very long transcripts, and cost less to read
- **Developer label:** "did a regression happen in chat names for claude, it shows untitled chat"
- **Agent label:** Keep the last tail-found title, skip non-title records, skip the head when cached
- **Changes:**
  - Not a regression, but a weakness found while checking: titles come from tail windows of at most
    1 MiB, and on a very long transcript (89 MB here) a long turn of big tool results can push the
    newest title record past them; the name then fell back to an older title or the first prompt.
    `AgentSessionLogParser` now keeps the last title a tail window found per transcript and uses it
    before the head (`resolvedClaudeTitle(tail:lastKnownTail:head:)`, pure). A newer title record
    still wins as soon as a window sees it.
  - `claudeTitle(fromRecordText:)` skips lines without "-title" before JSON-parsing them — same
    result, far less work on megabyte tails.
  - `displayChatName` answers from the (mtime, size) title cache before reading a transcript's first
    32 KB, so a quiet session with a known title costs a stat.
  - Tests: the title survives 1.2 MB of records written after it (and a mutation that removes the
    sticky title makes that test fail), a newer title replaces it, precedence, and a "-title" in
    prose does not confuse the prefilter.

### 2026-09-11 - The open panel's red blink stops at 5 s; icons resolved once
- **Developer label:** "how can we optimize that" (the notch's CPU while an agent works)
- **Agent label:** Bound the 10 Hz red blink, honour Reduce Motion, cache provider icons
- **Changes:**
  - `NotchAgentStatusView`: the red badge's blink is a 10 Hz `TimelineView` that only checked its
    5-second window when something else redrew the panel, so it could keep ticking indefinitely.
    It now wakes once at the window's end (`AgentTrafficLightAttention.blinkChange`) and is removed;
    under Reduce Motion it never blinks.
  - `AgentProviderIconView` resolved each app icon on every render (a disk check, NSWorkspace and a
    thumbnail redraw). New `AgentProviderIconCache` keeps one per source, re-resolved after ten
    minutes so a newly installed or updated app shows its icon. `AgentProviderIconSource` is now
    `Hashable`.

### 2026-09-11 - No periodic timers behind the traffic light
- **Developer label:** "how can we optimize that" (the notch's CPU while an agent works)
- **Agent label:** Replace the notch's 1 Hz timers with one-shot wakes at the exact deadline
- **Changes:**
  - New pure rules in `AgentTrafficLightAttention` (logic target): the red pulse lasts exactly
    4 s after a run ends, the five-second pill 5 s, the open panel's red blink 5 s — each with a
    "next change" date. `AgentTrafficLightIndicator` and `AgentTrafficLightLiveActivity` drop their
    `TimelineView(.periodic(by: 1))` wrappers (which redrew them every second for the whole run and
    re-ranked all findings each tick) and instead wake once, with `.task(id: deadline)`, at the
    moment a cue ends. The red window now ends at exactly 4 s instead of anywhere in 4–5 s.
  - `SecurityFindingsStore` wakes once when the next snooze ends (`snoozes` didSet arms it; only
    expired snoozes are dropped, never by finding id) — the removed tick had been what brought a
    snoozed finding back. Pure `SecurityFindingPriority.nextSnoozeExpiry`.
  - Tests: red pulse ends at 4 s with one wake, green/yellow always, inactive never, five-second
    pill only in its mode (and no wake when the mode is chosen late), blink 5 s, next snooze.

### 2026-09-11 - A DEBUG-only way to see Settings without a screen
- **Developer label:** "the settings should be enginered like apple does settings … while making any change make sure no regression happens"
- **Agent label:** Add a debug snapshot harness that renders Settings tabs and boards to PNG
- **Changes:**
  - New `Kannu/helpers/DebugSnapshot.swift` (compiled only in DEBUG): launched with
    `--kannu-snapshots <dir>` (optionally `--kannu-snapshot-tabs agentStatus,general,…`), Kannu
    renders every Settings tab exactly as the window builds it (`SettingsView.detailView(for:)`,
    grouped form, the real environment objects), a findings board built from fixtures (never
    ingested — ingest would prune the shared acknowledgements) and the notch dots in every state,
    light and dark, into PNGs plus 700 pt tiles, then quits. It returns before any monitor, hook
    migration or window starts. Rendering: offscreen borderless window grown to the form's full
    document height, layer tree drawn with `CALayer.render(in:)`, flipped to read top-down.
  - `KannuApp.applicationDidFinishLaunching` checks for the flag first (DEBUG only);
    `SettingsView.snapshotTabs(filter:)` and `AgentStatusSettings.snapshotFindingRows(_:)` are
    DEBUG extensions in `SettingsView.swift`. Release builds are unchanged.
  - Why: this Mac's Claude host has no screen-recording or accessibility access, so Settings
    changes could not be seen before; every Settings commit that follows is checked against
    before/after images. First use confirmed the Core Animation dots render the same as the
    SwiftUI previews in every state.

### 2026-09-11 - The traffic light breathes on Core Animation, not SwiftUI
- **Developer label:** "Kannu uses about 5% CPU while an agent works… is this a bit too much, will it draw down so much battery, how can we optimize that"
- **Agent label:** Move the lit-dot pulse to a Core Animation layer and honour Reduce Motion
- **Changes:**
  - The lit dot's breath was a SwiftUI `.repeatForever` scale/opacity animation
    (`ConditionalPulseModifier`), which re-laid out the whole notch view on the main thread on
    every display frame — up to 120 a second on this Mac's ProMotion screen — for as long as an
    agent worked, on every display. New `TrafficLightDot` (`TrafficLightDotView`, an
    `NSViewRepresentable` in the pattern of `AudioSpectrum`) draws the live dots with a CALayer
    and runs the breath as a CA animation group in the render server: same look (scale 1.3,
    opacity 0.5, 0.7 s ease-in-out, autoreverse), eases back to rest from wherever it was,
    capped at 30 fps, removed when off-window, and never breathes under Reduce Motion.
  - `AgentTrafficLightDots` gains `live` (the notch indicator); Settings and onboarding previews
    keep their plain circles. The pulse constants live in `TrafficLightPulseSpec` (logic target),
    pinned by `AgentTrafficLightAttentionTests`.
  - Measured on this Mac (M3 Pro, one ProMotion display, `top -l` over ~40 s, green light, no hook
    events): 53.1% CPU and 13,356 idle wakeups/s before; 0.9% and 12/s after. While hooks fire
    every ~2 s the average is ~8% with spikes to 18%, all rescan work, not the pulse — addressed
    next.

### 2026-09-11 - Copy a finding for your agent; finding text you can select
- **Developer label:** "make general descriptions in settings copy pasteable, give a copy button in each adr detection for them to copy and paste int their agent"
- **Agent label:** Add plain what-it-means / what-to-do help per finding, selectable text, and a safe "Copy for agent" request
- **Changes:**
  - New `SecurityFindingGuide` (logic target): a family per rule (the five ADR Discovery rules,
    Detection, hidden text and its bidi case, secrets, sensitive files read or changed, new MCP
    servers, anything else) with a plain "What it means" and "What to do" written to read as
    advice in Settings and as a task for an agent; and `agentPrompt(for:)`, the request "Copy for
    agent" puts on the clipboard.
  - What the request never carries: a key (Kannu never has one), the decoded hidden text (moved
    out of `evidence` into a new `AgentSecurityFinding.kannuOnlyEvidence`, which is empty by
    default so a rebuild that forgets it can only hide a line, never leak one; Settings and the
    notch show `displayedEvidence`), a chat name, a session id or a transcript path. The unattended
    finding's line no longer shows a session id; its id is computed from the old line, so
    acknowledgements hold. Values from files and tools (server names, paths, ADR's words) go
    through `oneLine`: control and separator characters become spaces, direction controls,
    zero-width and tag characters and variation selectors are dropped, and each value sits on its
    own "- " line under a header saying to treat it as data.
  - Settings › Security findings: each row shows "What it means" and "What to do", its text is
    selectable, and a **Copy for agent** button (first in the row) shows "Copied" for two seconds
    without changing width. Malicious ADR Detection analyses get the same button; the section's
    captions and messages are selectable too (text only, never toggle labels).
  - Notch: the pinned high finding gets **Copy for agent** beside Details and Acknowledge.
  - `copyAgentPrompt(for:)` on the findings store writes the clipboard; the text is never logged.
    Rule prefixes (`hidden_text_`, `secret_`, `sensitive_file_`, `detection_`) are now constants
    on their types.
  - Tests: `SecurityFindingGuideTests` (families for every rule a builder produces, plain texts,
    hidden text never copied, only hidden text has Kannu-only lines, secret and sensitive-file and
    unattended and Detection prompts never name the chat or the session, ADR words and paths
    present, forged lines and invisible characters removed); the hidden-text test follows the moved
    line.

### 2026-09-11 - Hook v37: find the agent's terminal above a detached hook
- **Developer label:** Tab jump for every terminal agent (fix found in live verification)
- **Agent label:** Walk up the process tree for the terminal; look only for terminal agents
- **Changes:**
  - Found on this Mac after installing v36: the `tty_sid` in a Claude status file changed on every
    event. Claude Code starts each hook in a session of its own, so the hook's session never has the
    terminal; v35's lookup came back empty and, because the session id kept changing, ran on every
    event.
  - `ancestor_terminal()` walks from the hook up the parent chain (libproc `pbi_ppid`) to the nearest
    process with a controlling terminal and records that terminal, its session leader
    (`os.getsid`) and the leader's start time. Only terminal agents look (Codex, Copilot CLI, Gemini
    CLI, Qwen Code, opencode): Claude's session file already names its process and IDE agents have
    no terminal. The lookup runs when a session starts, on each prompt and on a conversation's first
    event, and is carried in between.
  - Copilot CLI detection: `COPILOT_CLI`, `/dev/tty`, or a conversation already filed as Copilot;
    the process walk runs only on a conversation's first event, so VS Code events stay cheap.
  - Tests: a hook run under `script` in a session of its own still finds the terminal; Claude records
    none; a Copilot conversation stays Copilot without the variable; the no-terminal case records
    neither key.

### 2026-09-11 - opencode, through a small plugin
- **Developer label:** More agents: opencode
- **Agent label:** Add an opencode plugin that feeds the shared status script
- **Changes:**
  - New `OpencodePluginSource.swift` (logic target): the plugin as a raw literal with its own
    version marker and the status script's path baked in as a JSON-quoted string. It maps
    `session.created` (subagents with a `parentID` skipped), `chat.message`, `tool.execute.before`
    / `after` (arguments carried to the post-tool event so the sensitive-file check sees them),
    `permission.asked` / `permission.updated` (the pre-2026 name) / `question.asked`, their replies,
    `session.idle`, `session.error` and `session.deleted` onto the Claude-style events the script
    already understands; titles come from `session.updated`. Every call is `Bun.spawn` with an argv
    array and the details on stdin, never awaited, always wrapped; text is capped at 200 KB.
  - Installer: provider `opencode` — script `~/.config/opencode/kannu-agent-status.sh` (outside
    `plugins/`, which opencode loads wholesale), plugin `~/.config/opencode/plugins/kannu-agent-status.js`.
    Installed only when the plugin carries Kannu's marker; a plugin-version migration beside the
    script-version one; uninstall removes both (the layout's own-file rule). Not auto-installed; the
    row says "Not found on this Mac" until opencode has run here.
  - Tests: `OpencodePluginTests` in JavaScriptCore with a recording `Bun.spawn` (factory and hooks,
    the full event ladder, subagents skipped, argv never carries text, spawn failures swallowed,
    quoting) plus `node --check` as an ES module. Also run by hand under node against the real
    status script: title, working folder, yellow on a permission prompt, a secret in the prompt and
    an SSH key read all landed in the status file.
  - Unverified live: opencode is not installed here; the plugin API and the `plugins/` folder name
    follow opencode's docs and source as of 2026-09.

### 2026-09-11 - Hook v36: Copilot CLI, Gemini CLI and Qwen Code
- **Developer label:** More agents: Copilot CLI fix + support, Gemini CLI + Qwen Code
- **Agent label:** Label Copilot CLI apart from VS Code and add Gemini CLI and Qwen Code hooks
- **Changes:**
  - Hook script v36 (mirror and embedded copy regenerated; no backslash):
    - Copilot CLI already read Kannu's `~/.copilot/hooks` file and was filed as "vscode". Events
      from that file with `COPILOT_CLI` set or a controlling terminal now become "copilot"
      (VS Code's extension host has none; anything unclear stays vscode). Its `PermissionRequest`
      no longer paints yellow — it fires before Copilot's own rules and auto-allow — and a
      v35 `vscode-<id>.json` for the same session is removed.
    - Notifications without a matcher (VS Code/Copilot CLI, Gemini CLI, Qwen Code): only
      `ToolPermission`, `permission_prompt` and `elicitation_dialog` are yellow; idle reminders and
      other notices write nothing. Claude's matcher-scoped groups are unaffected.
    - Gemini CLI events: `BeforeAgent` (thinking; prompt scans; resets the error count),
      `BeforeTool` (executing; tool-input secret scan), `AfterTool` (thinking; hidden-text and
      sensitive-file scans, never the secret scan), `AfterAgent` (stopped).
    - Gemini CLI, Qwen Code and Copilot CLI get `{}` on stdout, also from the no-python fallback
      (Gemini parses stdout as JSON and falls back to stderr when it is empty).
  - Installer: providers `gemini` (script `~/.gemini/kannu-agent-status.sh`, groups in
    `~/.gemini/settings.json` with the handler name `kannu-agent-status` and millisecond timeouts)
    and `qwen` (`~/.qwen/settings.json`, Claude-style groups). A settings file with comments or
    trailing commas is refused with a plain reason instead of being rewritten. The merge and strip
    are pure functions on `AgentHookLayout`; the event tables move there too. VS Code's own file
    gains `Notification` and `SessionEnd`; Codex keeps its list (it validates strictly). The new
    tools are never auto-installed at first launch; their rows say "Not found on this Mac" and
    disable Install until the tool has run here (`~/.gemini` alone is Antigravity's too).
  - App: icons, labels ("Copilot CLI", "Gemini CLI", "Qwen Code", "opencode"), click-through through
    the hook's terminal, and `holdsAwaitingInput` lists the four new hook-only ids (REGRESSIONS 12).
    The VS Code row reads "VS Code and Copilot CLI". Not done: the detected-editors grid (cut).
  - Tests: 11 hook-script cases (VS Code without a terminal, Copilot's PermissionRequest and
    Notification, the old vscode card replaced, Gemini's event ladder and `{}` everywhere including
    without Python, Gemini results never secret-scanned, Qwen's PermissionRequest and idle prompt,
    Qwen yolo, Claude's matched Notification unchanged), layout merge and strip, event tables, tool
    presence, and the hold rule for the new ids.
  - Unverified live: none of the three CLIs is installed here. Needs a live check when they are:
    whether hooks inherit `COPILOT_CLI`, Copilot's PascalCase `Notification`, Gemini's event order.

### 2026-09-11 - One table for where every hook lives
- **Developer label:** Groundwork for more agents
- **Agent label:** Refactor hook install, uninstall, detection and migrations onto a single layout table
- **Changes:**
  - New `AgentHookLayout.swift` (logic target): `AgentHookProvider` moves here; per provider the
    script and every settings file (shape: flat entries, matcher groups or a file of Kannu's own;
    written always or only when present), plus shared settings uninstall leaves alone (Codex
    `features.hooks`).
  - `AgentHookInstaller`: the path properties forward to the layout; `uninstall` strips every
    listed file and removes Kannu's own ones; `checkInstalled` is one rule (script present and any
    listed file carries the required events) with the per-provider event lists kept; `stripEntries`
    routes by the listed shape instead of a separate set; the Antigravity merge, the script-version,
    legacy-script and event-argument migrations iterate the layout. Behaviour unchanged.
  - REGRESSIONS entry 6: guard now exists. `AgentHookLayoutTests` pins the table and scans the
    installer's code (not comments, not the embedded script) for hook path literals.

### 2026-09-11 - Notice new MCP servers; Discovery scans follow server changes
- **Developer label:** Local security checks (new MCP servers)
- **Agent label:** Watch agents' MCP settings for added servers and fix the dropped config-change scan
- **Changes:**
  - New `MCPServerWatch` (logic target): the settings files of Claude Code (user and per-project
    scopes in `~/.claude.json`), Claude Desktop, Cursor, VS Code (`.json5Allowed`), Codex
    (`[mcp_servers.<name>]` headers, sub-tables folded), Gemini CLI, Qwen Code and opencode, plus
    project files in the folders sessions run in — never inside Desktop, Documents, Downloads, iCloud
    or cloud storage, or other volumes, so no permission prompt. Trust on first use: the first read of
    a file learns silently; a missing file counts as "no servers", an unreadable one keeps what was
    known. Additions become medium findings whose summary (pushed) has the name and app only; a
    "Runs:" line keeps lowercase package-like arguments or a URL's scheme and host, never tokens,
    env values or URL paths. Removed servers drop their finding; added again is a new finding.
  - Reads happen on a utility queue once a minute and only re-parse files whose date or size moved.
  - Bug fix: a config change seen inside the five-minute debounce moved the baseline and was then
    forgotten, so the "config changed" Discovery scan never ran. `ADRScanTrigger` keeps it pending
    until the window passes; any scan clears it. It compares declared servers, not modification
    times — Claude Code rewrites `~/.claude.json` constantly, which would otherwise mean a scan every
    five minutes.
  - Settings › Security findings: "Notice new MCP servers" (on; turning it off forgets the baseline
    and the findings); footer lists the check. Defaults: `watchMCPServers`, `mcpServerBaseline`,
    `mcpServerAdditions`.
  - Tests: `MCPServerWatchTests` (every format, JSONC, CRLF TOML, secret-free "runs", protected
    roots, first look silent, removal and re-add, missing vs unreadable, cache, inventory, the
    trigger keeping and clearing a change).

### 2026-09-11 - Hook v35: secrets, sensitive files and the agent's terminal
- **Developer label:** Local security checks + tab jump for every terminal agent
- **Agent label:** Add local secret and sensitive-file checks and a per-session terminal locator to the hook
- **Changes:**
  - Hook script v35 (mirror and embedded copy regenerated, still no backslash, Python 3.9 and 3.13,
    no warnings under `-W error`):
    - `secrets`: API keys and private keys in `UserPromptSubmit`/`beforeSubmitPrompt` prompts and in
      tool input at `PreToolUse`/`preToolUse`/`beforeShellExecution`/`beforeMCPExecution` — never in
      tool results. Eleven vendor patterns plus PEM/OpenSSH/PGP private-key blocks; placeholders
      (`EXAMPLE`, `XXXXXXXX`, low-variety bodies, keys with no digit) skipped. Only kind, vendor
      prefix, length and a 12-hex SHA-256 fingerprint are written; one sighting per key and place;
      the same `tool_use_id` never counts twice; at most five per session.
    - `sensitive_paths`: at post-tool events, paths from file tools (`file_path`, `target_file`,
      `path`…, JSON-string inputs, Codex `apply_patch` headers) and from shell commands (`shlex`
      with punctuation splitting; redirections, `tee`, `cp`/`mv` targets, `sed -i`, `security`,
      `crontab`, `launchctl load`), classified into thirteen categories; startup files, autorun
      locations and agent settings count only when changed; `.env.example` and friends skipped; a
      failure event marks the sighting `failed` until an attempt succeeds.
    - `tty`, `tty_sid`, `tty_start`: the session leader's controlling terminal and start time from
      libproc through ctypes (`proc_pidinfo` + `devname`, about 2 ms, no process spawned), looked
      up only when the session leader changes. Python's `os.ttyname` on `/dev/tty` only answers
      `/dev/tty` on macOS, which is why it is not used.
    - Two off markers (`.kannu-secrets-off`, `.kannu-sensitive-paths-off`); a check that is off
      skips its scan and drops its list. Everything is carried on every write, sticky path included.
    - Cost: 2–6 ms more per event on a 100–120 ms hook, mostly compiling the longer script.
  - Swift: `SecretSighting` and `SensitivePathSighting` (logic target) with tolerant parsing,
    plain titles, severities decided in Swift (secret: high when the agent used it in anything but a
    file edit; file: medium for `.env`, shell history and `.vscode/settings.json`, else high) and ids
    that survive later counts. `HookSightings`/`HookSightingRecords` gain both lists;
    `TerminalLocator(hookFile:)` and `matches(liveTTY:liveStart:)` so a reused pid or tty never opens
    a stranger's tab; `AgentSessionStatus.terminal` (locator, `self ?? source`).
  - Click-through: Codex sessions without a pid, and terminal agents Kannu has no icon for yet, now
    open their exact Terminal/iTerm2 tab or tmux pane from the hook's terminal.
  - Settings › Security findings: "Look for secrets in prompts and tool calls" and "Watch for agents
    touching sensitive files" (both on; local; search entries); footer lists all of Kannu's checks.
  - Tests: 13 hook-script cases (secret never stored, tool results ignored, placeholders, one
    sighting per call, post-tool only, shell parsing, failed attempts, `.env` vs example, Cursor and
    Codex shapes, carry and sanitising, off markers, no terminal, a real pseudo-terminal through
    `script`), `SecretSightingTests`, `SensitivePathSightingTests`, container and locator tests.
  - Docs: `docs/ADR.md` §4 bullets; REGRESSIONS entry 1 (regex edges without backslashes) and
    entry 7 (the two lists, the `terminal` locator).

### 2026-09-11 - One container for what the hook's local checks see
- **Developer label:** Local security checks (groundwork)
- **Agent label:** Refactor hidden-text plumbing into a shared sightings container before adding more checks
- **Changes:**
  - New `HookSightings.swift` (logic target): `HookSighting` protocol (key, first/last seen, cap,
    finding) with the set union moved from `HiddenTextIncident`; `HookSightings` (one list per check,
    parsed from the status file, unioned across seams); generic `HookSightingRecord` with the
    least-recently-seen eviction moved from `HiddenTextIncident.Record`; `HookSightingRecords`, the
    persisted lists, decoding a missing or unreadable list as empty so one bad list never loses the
    others.
  - `AgentSessionStatus.hiddenText` becomes `sightings`; `carryingExtras` unions the container. The
    secrets and sensitive-path checks that follow add a list, not a field (REGRESSIONS entry 7 note).
  - Defaults key `hiddenTextIncidents` becomes `hookSightingRecords` (hook v34 never shipped; a
    sighting saved by a dev build is re-read from its status file while that exists).
  - Behaviour unchanged. Tests: `HookSightingsTests` (parse, per-kind union, record round trip,
    unreadable list); hidden-text and reconciler tests moved to the new names.

### 2026-09-11 - "Still waiting on you": one reminder push when an agent waits too long
- **Developer label:** Waiting reminder + tab jump
- **Agent label:** Push once more when a session has waited on the user past a chosen time
- **Changes:**
  - `AgentWaitReminder` (logic target): a wait starts when a session is first seen yellow and keeps
    that start until it leaves yellow (so a Cursor transcript yellow whose timestamp moves is still
    one wait); one reminder per wait; leaving yellow and coming back is a new wait; waits already
    overdue in the first seconds after launch, or when the setting is switched on, are marked,
    not pushed — no burst on relaunch and no instant push from changing the setting.
  - The bridge watches the per-session list, arms a one-shot for the moment the next wait crosses
    the threshold (the list does not republish then), and pushes "Still waiting on you — Claude Code
    has waited 10 minutes for your answer." (the app's name and the wait only; webhook state
    `still_waiting`).
  - Settings › Mobile notifications: "Remind me when an agent is still waiting" — Off (default),
    after 3, 10 or 20 minutes. 20 is the cap because hook-only yellows end at the 30-minute stale limit;
    5 is left out because an uncorroborated yellow ends at exactly 5.
  - Tests: `AgentWaitReminderTests` (once per wait, a new wait reminds again, moving timestamps, leaving
    yellow cancels, no launch burst, off clears, next check, hidden sessions ignored).

### 2026-09-11 - Click-through opens the exact Terminal or iTerm2 tab and tmux pane; a live chat is never resumed
- **Developer label:** Waiting reminder + tab jump
- **Agent label:** Pick the agent's own terminal tab (and tmux pane) on click, and stop resuming live Claude chats whose host the parent walk cannot reach
- **Changes:**
  - The parent walk (`AgentSessionOpener.hostChain`) now also reads the agent's controlling terminal
    (`kp_eproc.e_tdev` + `devname_r`, no process spawned while a row renders) and notes a tmux server
    on the way to launchd.
  - Terminal.app (tabs have a `tty`) and iTerm2 (sessions have a `tty`): after the app activates, an
    AppleScript selects the tab or split whose terminal is the agent's and raises its window
    (`TerminalTabMatcher`, `TerminalTabLocator`; an Automation refusal is remembered for the launch and
    the old window raise takes over). Other terminals stay at "bring the app forward".
  - tmux: `list-panes` finds the pane by its tty, `select-window`/`select-pane` focus it, `list-clients`
    finds the terminal showing that session (switching the most recent client when none does), and
    that terminal's tab comes forward. tmux is found in the usual install folders, run without a
    shell, with a 2 s deadline; every tty and pane id is validated before it becomes an argument.
  - Fixed: a live Claude session in tmux, `screen` or ssh has no GUI app up its parent chain, and when
    its card was dim the click fell through to `claude://resume` — a second host for a live transcript.
    The decision now lives in `AgentClickThroughPolicy` (tested); REGRESSIONS entry 13.
  - Settings › Agents › Click-through is always shown, with "Open the exact terminal tab" (on); the
    Apple Events usage text names terminals.
  - Tests: `TerminalTabMatcherTests` (families, injection-proof validation, scripts, tmux parsing and
    client choice), `AgentClickThroughPolicyTests`.

### 2026-09-11 - Usage forecast, a gauge near the limit, "resumes at" on rate-limited stops
- **Developer label:** Usage forecast + alerts
- **Agent label:** Forecast each usage window from Kannu's own readings, cue a nearly full limit beside the lights, say when a rate-limited chat can resume, and push a nearly full limit if the user opts in
- **Changes:**
  - `UsageForecast` (logic target): providers report only "percent now", so Kannu keeps its own
    readings per window (throttled to one per 2 min, restarted when the window rolls over or its reset
    moves) and fits a least-squares pace over 90 min for the 5-hour window, 24 h for weekly and billing
    windows. Outlooks: steady, lasts until reset (with the projected percent), hits the limit at a
    time, at the limit. The Usage tab shows a line under a bar only when it matters ("At this pace:
    full by 3:40 PM", "about 88% at reset", "Limit reached — resets …"). Samples persist for 8 days.
  - `UsageAlertPolicy`: near limit = a live window at 95 %+ or marked critical; one push key per window
    instance (id + reset); "resumes at" only when the matching window really is full, because a 429 can
    also be short-term throttling.
  - `UsageAlertManager` gathers readings from the Claude sources the monitor already reads and the
    Codex/Cursor results of the Usage tab. "Check Codex and Cursor limits in the background" (off by
    default) makes the same request every 5 min, only while such an agent is working and only after a
    foreground read succeeded this launch, so it can never raise a credential prompt out of the blue.
  - Fresher Claude numbers: between the 10-minute full reads, the statusline file alone is re-read when
    it changed (at most once a minute) and merged with the other two sources as last read.
  - A white gauge beside the lights when any limit passes 95 % (on by default, local); it rides along
    with the lights and never puts the island up by itself; it clears at the reset. A stopped chat
    that hit a full window reads "Stopped · rate limited (429) · resumes 3:40 PM".
  - "Push when a usage limit is almost reached" (off): one push per window cycle with the provider,
    the window and the reset — no chat names. The bridge's provider switch is now one `send`.
  - Tests: `UsageForecastTests` (outlooks, admission, captions, near-limit, push keys, resumes-at,
    Claude readings) and three statusline fast-path cases.

### 2026-09-11 - Hidden text in what agents read and write, checked locally in the hook
- **Developer label:** The one inline thing worth adding cheaply, no model: the deterministic hidden-Unicode (ASCII-smuggling) check on tool results via hooks — local, instant, no data leaves. Say if you want that. add this too
- **Agent label:** Hook v34 scans every hook payload for hidden Unicode and records sightings as Kannu-native security findings; telling the agent is opt-in
- **Changes:**
  - Hook script v34 (mirror and embedded copy, byte-identical): `scan_hidden_text` walks the
    *decoded* payload (never the raw text, so escaped characters and Cursor's JSON-string
    `tool_output` are judged by what they decode to), attributes each string to where it came from
    (tool result, prompt, tool input, agent reply), and classifies four techniques written from their
    public specifications — Unicode tag characters (UTS #51 flag sequences excluded), variation-
    selector runs of 4+ (decoded, Butler 2025), right-to-left overrides on a line with no right-to-left
    letters (Trojan Source), zero-width runs of 10+ (two-symbol runs decoded as bits, Rehberger's
    Sneaky Bits). Nothing ported from ADR, so NOTICE is unchanged. Scanned before the directory lock;
    ASCII payloads return in well under a millisecond, a 1 MB non-ASCII worst case in tens of ms.
  - Status-file key `hidden_text`: up to three sightings (kind, where, tool, count, events, a
    printable-ASCII preview, first/last seen, tool_use_id), carried on every write like `unattended`;
    the same tool call never counts twice (Claude's parallel gated PreToolUse; PostToolUse after
    PreToolUse) and the same hidden message merges.
  - One `emit()` writes all stdout. Without the opt-in marker it prints today's line — except for
    **Codex, which rejected that line on every event** (strict schemas; empty stdout is success) and
    now gets nothing. With "Tell the agent when hidden text is found" on, a new sighting adds a
    factual note: Claude Code `hookSpecificOutput.additionalContext` (+ a `systemMessage` for the
    user) on PostToolUse/PostToolUseFailure/UserPromptSubmit/PreToolUse, VS Code and Codex on
    PostToolUse, Cursor `additional_context` on postToolUse; never on Stop; never the decoded text.
    Settings reach the script as two marker files in the status directory.
  - Also fixed in the script: a non-object JSON payload (`[]`, `42`) and a deeply nested one crashed
    it before its allow line.
  - Swift: `HiddenTextIncident` (logic target) parses the entries as untrusted input and decides
    severity (high when the text decodes to something readable), plain titles, a summary that never
    holds the decoded text, and a finding id from what never changes for one sighting. The monitor
    lifts it onto `AgentSessionStatus.hiddenText` (union in `carryingExtras`); `SecurityFindingsStore`
    keeps sightings (cap 50) past their session until acknowledged and keeps the two marker files in
    step with Settings ("Look for hidden text in what agents read", on; "Tell the agent when hidden
    text is found", off). The webhook now sends the finding's source as `finding_source` (the base
    body's `"source": "Kannu"` used to win the merge and drop it).
  - Guards: `.githooks/pre-commit` now compares the two hook bodies and rejects a backslash in the
    Python; `HookScriptTests` gains provider/stdout/raw-payload support and cases for every technique,
    false-positive guard, location, carry, de-duplication, opt-in output per host, Codex silence and
    malformed payloads, plus an embedded == mirror test; `HiddenTextIncidentTests` covers parsing,
    severity, identity, wording, merging and persistence. REGRESSIONS entries 1 and 7 updated.
  - Known limits: Claude's WebFetch hands hooks a summary, so smuggling in a raw web page may never
    reach the hook (Bash `curl`, Read and MCP fetchers are covered); payloads over ~1 MB never reach
    Python at all (the existing env-var hand-off hits ARG_MAX); Codex output verified against its
    source, not a live Codex.

### 2026-09-10 - The media card opens the browser tab that is playing
- **Developer label:** can media player like chromed tabs or safari tabs also open to the exact media screen playing
- **Agent label:** After activating the browser, select the tab whose title carries the playing track (Safari and Chrome-family), best-effort
- **Changes:**
  - `BrowserTabMatcher` (pure, tested): which browsers can be asked (Safari; Chrome, Brave, Edge,
    Vivaldi, Chromium — Firefox exposes no tabs, Arc speaks another dictionary), the two AppleScripts
    (list `window\ttab\ttitle`; make a tab current, raise its window, activate), and the match: the
    tab whose normalised title contains the track title, else most of its words, the artist breaking
    ties, then the frontmost window; nothing convincing → no tab. Normalisation drops YouTube's
    "(N) " counter and site suffixes ("- YouTube", "| Spotify", …).
  - `BrowserTabLocator` runs it off the main actor after `MusicManager.openMusicApp()` has
    activated the browser as before, so every failure — Automation refused (-1743, remembered for
    the launch so the click never re-prompts), no match, a script error — leaves the user in the
    browser on whatever tab it had. macOS asks "Kannu wants to control <browser>" once per browser;
    the Apple Events usage text says why. `Defaults[.openPlayingBrowserTab]` (default on) turns
    the tab step off.

### 2026-09-10 - Analyze a finished chat with ADR Detection — opt-in, per chat, off by default
- **Developer label:** lets build this too … this needs to be supported but all this must be off by default and user has to manually opt in
- **Agent label:** Phase 3 of the ADR integration: run Uber's Detection over one Claude Code transcript on explicit request, with every model/provider/context knob exposed and nothing automatic
- **Changes:**
  - How upstream works (verified in `ADR/Detection` at df05577): `config_detector.yaml` is the knob
    set — `enable_triage` (off = no OpenAI at all), triage model `gpt-4o`, reasoning model
    `claude-sonnet-4-6`, `max_turns` 60, `timeout` 300 s, three local MCP context servers (threat
    intel reads a bundled YAML; none touch the network). The reasoning agent is a headless
    `claude -p … --mcp-config .mcp.json --disallowedTools file_edit,create_file,str_replace_editor
    --dangerously-skip-permissions` under the CLI's own auth (`ANTHROPIC_API_KEY` if set, else the
    login and its quota). `ADRBaseline` builds its OpenAI client eagerly, so Claude-only mode needs
    a placeholder key — the adapter sets one that is never sent.
  - Kannu-owned adapter `scripts/adr-analyze-session.py` (GPL; embedded in `ADRDetectionCommand`,
    a test pins the two identical): converts a Claude Code JSONL exactly as upstream's
    `_convert_conversation_to_messages` does, caps to the newest N messages, calls
    `ADRBaseline(config_data:).analyze_conversation`, prints a small verdict JSON and writes the
    full report. `ADRDetectionCommand` holds the `uv run --project` invocation and an environment
    **whitelist** (PATH, HOME, LANG, and only the keys the user chose) as data — REGRESSIONS entry 8.
  - `ADRSessionAnalysis`: the verdict record (persisted, capped at 50); a malicious verdict becomes
    a `.detection` finding — high at confidence ≥ 0.8 (ADR's own triage threshold), medium below —
    and rides the existing shield/pill/card/push path. Clean verdicts are records, not findings.
  - Consent, twice: turning the feature on shows an alert naming what leaves the Mac and where;
    each run confirms again (transcript name, message cap, providers, quota note) until the user
    unticks "Confirm before every analysis". Nothing runs without a click on a finished chat's
    context menu. `ADRConnection.validateDetectionCheckout` checks the checkout (pyproject,
    `guardrail/adr_agent`, `.venv`, `uv`).
  - Settings › Security findings gains the Detection block: checkout picker + clone/sync command,
    reasoning model, "Use an Anthropic API key" (else the login's quota), triage toggle + model +
    OpenAI key, three context toggles, timeout, message cap, confirm-each-run, recent analyses with
    Reveal/Forget. Keys live in the Keychain (`SecureSecretsStore`, reusing `openaiAPIKey` and
    `claudeAPIKey`). All defaults off/none.
  - Tests: `ADRDetectionCommandTests` (arguments, validation rejects permission/tool flags,
    environment whitelist, embedded == mirror, the adapter's `--convert-only` conversion via
    python3), `ADRSessionAnalysisTests` (parse, adapter errors surfaced, finding mapping, titles).
    `docs/ADR.md` section 8. Sensor deferred.
  - Follow-up: the consent moved from an `NSAlert` inside the toggle's binding setter (a nested
    run loop there fought the toggle's own state update and the switch fell back) to a SwiftUI
    `.alert`; consent and the section footer rewritten in plain sentences.

### 2026-09-10 - An unanswered prompt stays yellow for as long as the session is still waiting
- **Developer label:** the yellow shouldnt die out if not attended, like an active yellow became inactive chat in kannu since it was open for long time
- **Agent label:** Hold `awaiting_input` on liveness evidence instead of a 5-minute clock; the clock stays only as the fallback for waits nothing can corroborate
- **Changes:**
  - Why it died: `resolveHookState` turned `awaiting_input` invisible after `awaitingInputStaleMs`
    (300 s, a private constant with no test), the hook script preserves the file's `ts` while a
    prompt is pending (by design — every earlier false-yellow fix made the clock yellow's only
    exit), an aged yellow could never be promoted by passive evidence, and at 30 min the stale
    deletion handed the card to the passive twin as a dim chat (or green, a pending `tool_use`
    reading as a running tool).
  - `resolveHookState(…, holdAwaitingInput:)` keeps yellow regardless of age when held. Pure rules:
    `holdsAwaitingInput` (Claude: process alive and transcript tail `.toolInFlight`; Cursor:
    `hasPendingToolApproval`; vscode/codex/antigravity: hold — nothing can corroborate or refute,
    a newer event or the 30 min stale cap ends it; others: no) and `awaitingInputOutlivesStaleCap`
    (Claude corroborated only). Passive paths still never claim yellow; the tail corroborates.
  - Monitor: `buildClaudeSessions` runs before `parseHookSessions` and returns the live tail per
    conversation; the parser computes the hold per file, passes it to the ladder, and exempts a
    corroborated Claude prompt's file from the stale deletion (SessionEnd, a newer event, or the
    process dying still end it). Cursor's corroboration is the previous cycle's transcript analysis.
  - Caffeinate: yellow held the Mac awake only because it went invisible at 5 min; the bound is now
    explicit (`awaitingInputCaffeinateSeconds`, derived from the same constant) and
    `CaffeinateManager` arms an `awaiting window` recheck at the earliest qualifying yellow's
    expiry, since the session list does not republish at that moment.
  - Known: after a permission is approved, a long tool run shows yellow until `PostToolUse` (no
    event fires at approval; nothing on disk separates "approved and running" from "still asking")
    — yellow beats vanished. Hook-only providers closed with a pending prompt show yellow until the
    stale cap instead of 5 min.
  - Tests: ladder held/unheld, per-provider hold table, stale-cap exemption, reconciler (held yellow
    survives passive tool-in-flight, dies with the process, aged yellow not promoted), caffeinate
    window and recheck date. REGRESSIONS entry 12; entry 2 cross-reference; `docs/CAFFEINATE.md`.

### 2026-09-10 - Click-through lands on the exact chat inside Claude Desktop
- **Developer label:** also can we make the clickthrough redirect not just to app, but the actual chat they are clicking on … Claude Desktop live Code session this is the most important one, research on internet to see how it could be done
- **Agent label:** Open a Claude Code chat hosted by Claude Desktop's Code tab through Desktop's own session route (`claude://claude.ai/epitaxy/local_…`), resolved from its on-disk session index
- **Changes:**
  - Research (Desktop 1.46388.4 bundle + docs/issues): Desktop's URL handler has two focus routes
    for its own `local_` id, both creating nothing — `claude://code/continue?session=<id>` (roster
    lookup, behind a feature gate: on this machine it logged "code entry deep link gated off" and
    did nothing) and `claude://claude.ai/epitaxy/<id>` (direct in-app navigation, ungated —
    verified: `setFocusedSession` for the id in Desktop's log, no new `claude` host). Kannu uses
    the second. `claude://resume?session=<cli uuid>` — what Kannu used for stopped chats —
    imports the transcript unless a Desktop chat with that exact id exists, and Desktop's id
    diverges from the CLI id after a resume/clear/compaction: that is why a live-session `resume`
    spawned a duplicate host. There is no other door (no port, no socket, no AppleScript
    dictionary, remote debugging stripped); Accessibility needs `AXManualAccessibility` on the
    Electron app and stays a possible later fallback.
  - New `ClaudeDesktopSessionIndex` (Foundation only, in the logic test target): reads
    `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json`
    (records are 100+ KB, so on a utility worker with a per-file `(mtime, size)` cache), maps every
    CLI session id — `cliSessionId` plus the lineage keys — to Desktop's `local_…` id (direct match
    beats lineage, non-archived beats archived, newest activity wins; an archived-only match still
    resolves because `continue` on it is a safe no-op), classifies a live session as Desktop-hosted
    from `~/.claude/sessions/<pid>.json`'s `entrypoint`, and builds the link (rejects `last`, bare
    UUIDs and anything outside Desktop's regex, so the path carries only id characters). No
    process environment is read.
  - `AgentSessionStatus.desktopSessionID` — a locator like `hostPID`, set in `buildClaudeSessions`
    (a live session only when Desktop-hosted, so a terminal session once imported into Desktop keeps
    opening its terminal; a dead process takes any match), carried by `carryingExtras` as
    `self ?? source` (REGRESSIONS entry 7 field set grows).
  - `AgentSessionOpener`: chats Desktop knows open via the session route (live and stopped), stopped
    chats it has never seen still `resume` (import), never a live one; a Desktop-hosted session
    the index has not resolved yet activates the app without the pointless AX title raise. After
    the link Kannu also activates Desktop, covering a handler disabled by policy. Tooltip reads
    "Open chat in Claude" for deep links.
  - Tests: `ClaudeDesktopSessionIndexTests` (records, resolver precedence, id map, attach rule,
    link, file enumeration, cache), reconciler arms, retention, reconstruction.

### 2026-09-09 - A stopped card names only the error that ended the run
- **Developer label:** so now a chat completed successfully, that shows as stopped and shows 1 tool error, that tool error gives the user a wrong impression that the task also was not successful, so only report errors that made the process stop, else that error is irrelevant for the user right
- **Agent label:** Replace the per-turn tool-error count on the card with a run verdict set only by run-terminating signals
- **Changes:**
  - "Stopped · N tool errors" is gone. `tool_errors` was an unordered per-turn sum of
    `PostToolUseFailure` events, and on this Mac a failed tool result occurred 748 times inside turns
    the agent recovered from versus 4 times at the end of one — it measured recoveries, not outcomes.
    The hook still counts it (diagnostic, pinned by tests) but nothing displays it.
  - New `AgentSessionStatus.runError: RunError?` (`.apiError(status:)`, `.failed`; nil = clean),
    rendered as "Stopped · rate limited (429)", "· API overloaded (529)", "· signed out (401)",
    "· API error N", "· failed" — only on stopped and retained cards. Set by: hook v33's
    `ended_on_error` (Claude `StopFailure`, an Antigravity `Stop` carrying an error; kept across a
    later stopped write so the label cannot flicker, cleared by any non-stopped write), the Claude
    transcript's `assistant` record with `isApiErrorMessage: true` (`system`/`api_error` retries stay
    bookkeeping; a newer user prompt clears it by construction), Warp `Failed` (`Cancelled` stays
    clean), and Claude Desktop's newest `result` with `is_error` (`terminal_reason` deliberately not
    read — a cancel is not a failure). A tool failure never becomes a verdict, even when it was the
    last event before the stop (decided with the developer).
  - Seam rule: the verdict crosses `carryingExtras` as `RunError.preferred` — hook wins, the
    transcript fills a hook that has none, the more specific reason wins when both describe the same
    stop — never OR/max (REGRESSIONS entry 7 addendum explains why).
  - Tests: hook-script cases for recovered and trailing failures (clean), `StopFailure` (verdict,
    kept, cleared), interrupted `StopFailure`; parser cases for the API-error record with/without
    status, `isApiErrorMessage: false`, trailing bookkeeping, a new prompt, retry records; reconciler
    seam cases; `RunErrorTests`; Warp, Desktop and retention updates.

### 2026-09-09 - Kannu-run ADR scans, and a high finding that stays in the notch until acknowledged
- **Developer label:** also tell me how we can show that in ui, and how important is it, do we color code chats and also show something instead of traffic lights … make this persist until user action by default with control for user in settings
- **Agent label:** Phase 1 of the ADR integration: scan runner and cadence, priority UX in the notch and panel, push, and Kannu's own bypass-permissions finding
- **Changes:**
  - `ADRDiscoveryCommand` holds the invocation as data (`--json --output-dir <folder>`, `--policy`
    only when configured; never `--dry-run`, `--root`, `--diff`, `--explain`), pinned by tests in the
    REGRESSIONS entry 8 discipline. `SecurityFindingsStore.runScanNow` runs the connected binary on a
    utility queue with stdout discarded (the file is what matters), a 180 s cap, and exit 2 treated as
    a valid partial snapshot. Cadence: once a day, sooner when one of the five MCP config files changes
    on disk (mtime, checked once a minute, 5-minute debounce), and on "Scan now". "Let Kannu run
    scans" (default on once connected) turns the runner off for people who schedule Discovery
    themselves. A snapshot written by Kannu's own run is recorded with origin `kannu` even when the
    directory watcher ingests it first.
  - Security has its own vocabulary in the notch — a **monochrome shield**, never a fourth light
    colour and never a recoloured row, so red keeps meaning "finished". An unacknowledged high finding
    shows a shield glyph beside the dots (it follows the dots into the music pill too) and, by
    default, a **pill that persists until acknowledged** in the standalone light, laid out beside the
    dots rather than as a sneak peek (those auto-hide). Settings › "High-severity alerts in the
    notch": Until acknowledged (default) · For 5 seconds, then glyph · Glyph only · Off. Deferred to
    glyph-only while a Focus mode is active; no animation under Reduce Motion. The light branch now
    also renders when no agent is on screen but a cue is pending. Clicking the pill opens the panel.
  - Panel: the high finding is pinned above the primary session with Details (deep link to
    Settings › Security findings) and Acknowledge; other open findings appear as a count beside
    "Recent chats". Push: each new high finding once at priority 5, medium at 4 only when enabled;
    the webhook body carries rule, severity, source, asset and summary.
  - Kannu's own finding: hook script v32 remembers `permission_mode: bypassPermissions` (or a Codex
    `approval_policy` of `never`) for the session as `unattended`, the monitor lifts it onto
    `AgentSessionStatus.isUnattended` (additive — carried by `carryingExtras`, OR across the seam),
    and the store derives a high `.kannu` finding per visible session, dropped when the session is.
    ADR Discovery cannot see this on macOS: its process listing has no argv.
  - Tests: `ADRDiscoveryCommandTests` (5), native-finding and flag-carry cases, a hook-script case for
    the sticky flag, the reconciler asserts the flag rides the seam. `docs/ADR.md` gains the
    Kannu-run and attention sections.

### 2026-09-09 - Connect a separately installed ADR and show its security findings
- **Developer label:** plan how we could integrate adr uber changes to our system to setup that feature … plan it on based on seperate connect do not install with kannu, but support easy integration
- **Agent label:** Phase 0 of the ADR integration: detect the user's ADR install, guide the install, watch a snapshot folder, list Discovery findings with acknowledge and snooze
- **Changes:**
  - ADR (github.com/uber/ADR, Apache-2.0) stays a separate install the user owns. `ADRConnection`
    looks for `adr-discovery` / `adr-sensor` in `~/.local/bin`, uv's tool directory, Homebrew and
    `/usr/local/bin` (plus a user-set directory), reads their versions on demand, and hands Settings
    the exact `uv tool install …` / `pipx install …` lines with a Copy button when they are missing.
    Kannu ships no Python, runs no package manager, and never writes into the user's tool
    directories.
  - `ADRSnapshot` decodes Discovery's schema-1.0 JSON — assets, findings, review queue and the
    coverage block — strictly on the schema major (a 2.x file fails with a message, a 1.x minor
    keeps working) and leniently on everything else. The fixture is a real snapshot from this Mac,
    sanitised. `AgentSecurityFinding` joins each finding to its asset, gives it a stable id (digest
    of source, rule, subject and evidence, so acknowledgements survive re-scans and changed evidence
    is new again) and a human title; `SecurityFindingPriority` orders by severity then recency and
    picks the pinned high finding.
  - `SecurityFindingsStore` watches the snapshot folder (`~/.kannu/adr/discovery` by default, `0700`,
    changeable) with a dispatch source and shows the newest `snapshot-*.json`, whoever wrote it —
    the user by hand, a launchd job, or a fleet scheduler. Partial coverage (upstream exit code 2)
    is shown as such, never as "clean". Acknowledge and Snooze 24 h persist in Defaults and are
    dropped for findings that vanish.
  - Settings › Agents › **Security findings**: connection rows for Discovery and Sensor, install
    guidance callout, snapshot folder picker with Reveal, last-snapshot summary (assets, findings,
    coverage, catalog version), the findings list with severity glyphs and evidence, review-queue
    count, and a way to un-acknowledge. Three searchable entries. `docs/ADR.md` walks through
    installing, producing a snapshot, an optional launchd schedule (copyable, never installed by
    Kannu), the policy file, and what Kannu does and does not do with findings.
  - Nothing touches the traffic light or the notch yet; that is the next phase. No ADR code is
    included in Kannu, so NOTICE is unchanged.
  - Verified against this Mac: `uv tool install` of Discovery, a 17 s scan writing a 7 MB snapshot
    (99 % of it `coverage.boundaries_hit`, 31,808 entries; assets are 27 KB), one real finding —
    `notion` resolves its package at launch. The decode is one pass (schema major checked inside
    `init(from:)`, 0.10 s measured even unoptimised), runs on a utility queue, and only the result
    reaches the main actor; the snapshot is dropped after ingest. `adr-discovery` has no
    `--version` flag, so the version comes from `uv tool list` when the tool will not say.
  - Tests: `ADRSnapshotTests` (6) and `AgentSecurityFindingTests` (7).
### 2026-09-09 - Read Warp's database off the main actor
- **Developer label:** (found while verifying the next build: Kannu froze at launch)
- **Agent label:** Move the Warp SQLite read to a worker so the "access data from other apps" prompt cannot block the app
- **Changes:**
  - `warp.sqlite` lives in Warp's group container; the first `open()` raises macOS's
    `kTCCServiceSystemPolicyAppData` prompt and blocks until it is answered. `rescan()` did that open
    on the main actor, so every launch of the Warp-source builds froze the whole app for as long as
    the dialog was up (100 % of main-thread samples in `guarded_open_np`), and killing the app to
    rebuild dismissed the dialog unanswered, so the next launch asked again.
  - `WarpAgentStore.sessions` is split into the read (`loadRecentExchanges`, unchanged) and a pure
    `sessions(exchanges:…)` mapping; the one-call form stays for tests. The monitor keeps the last
    exchanges, refreshes them on a utility worker one at a time, and schedules a rescan when they
    changed. Warp users still see the prompt once — Kannu keeps working while it is up, and a
    "Don't Allow" simply leaves the Warp source empty.
  - `docs/REGRESSIONS.md` entry 11 records the rule for every passive source; a test pins the
    mapping as file-free.

### 2026-09-08 - Cache Claude Desktop audit reads; review follow-ups
- **Developer label:** can you look at the code rabbit comments
- **Agent label:** Act on the CodeRabbit review of PR #23
- **Changes:**
  - `ClaudeDesktopAgentSessionStore` now caches each parsed `audit.jsonl` against `(mtime, size)`,
    the same shape `AgentSessionLogParser` uses for its tail-state and title reads. Every full
    rescan was re-reading 32 KB leading + 16 KB trailing per file, up to 24 files, synchronously on
    the main actor — and FSEvents watches that root, so an appending session scheduled another pass
    every 0.35 s. Nothing in `Parsed` depends on the clock (the age ladder is applied by the caller
    from the file's mtime), so a hit is exact; a new test pins both the hit and the invalidation.
  - `scripts/create-dmg.sh` warns when an explicit `DMG_SIGN_IDENTITY` is not a Developer ID
    Application certificate, and the comment now records why the override is deliberately
    unfiltered: the release workflow never sets it — it resolves its own Developer ID identity and
    calls this script bare — so the override serves local runs, where the documented identity is the
    self-signed "Kannu Dev" cert. Refusing anything but Developer ID would break that case.
  - Three title fixtures in `AgentSessionLogParserTests` spelled the field `title`; Claude writes
    `aiTitle` / `customTitle`. The tests assert tail state and pass either way, but a fixture that
    misstates the schema misleads the next reader.

### 2026-09-08 - Hide Kannu's own /usage probe; keep ended chats listed for 69 seconds
- **Developer label:** write condition to ignore our /usage call from our chat detection of cluade; also when something is red and ended, persist it in recent chats for 69 seconds
- **Agent label:** Recognise the usage probe by process ancestry and remember its id; retain a red-then-gone chat as a dim card for 69 s
- **Changes:**
  - The manual usage refresh spawns an interactive `claude` and types `/usage`; that session
    registered like any other and showed as a phantom "Untitled chat" while it ran and a stopped
    card afterwards. The passive Claude path now recognises a session whose process descends from
    Kannu itself (parent-chain walk, same sysctl idiom as the click-through host lookup), skips it,
    and records its conversation id in `Defaults[.claudeUsageProbeConversationIDs]` (capped at 32)
    so the dead session file and the probe's own hook file are ignored afterwards too. The spawn is
    untouched — REGRESSIONS entry 8 — and deliberately so: giving the probe its own working directory
    would raise Claude Code's "trust this folder?" dialog, which would swallow the typed `/usage`.
  - A chat that was visibly red and then vanished (SessionEnd deleted its file, or its collapse and
    dim windows elapsed) now stays in Recent chats as a dim inactive card for 69 seconds
    (`AgentTrafficLightMapper.retainEndedSessions`, pure). The copy is `.inactive`, so the traffic
    light, caffeinate and the primary-session pick ignore it; it is dropped the moment the
    conversation is live or red again. The retained card keeps its "· N tool errors" suffix.
  - Tests: `RecentChatsRetentionTests` (7) and `UsageProbeExclusionTests` (3).

### 2026-09-08 - Name Claude chats the way Claude does
- **Developer label:** also chat names, why do they not match the labels in claude
- **Agent label:** Read `custom-title` before `ai-title` when naming a Claude session
- **Changes:**
  - Claude Code keeps two title records per transcript, rewritten every turn: `custom-title`
    (`customTitle`, what the desktop app and `/resume` display, user-renamable) and `ai-title`
    (`aiTitle`, the model's own name). Kannu read only `ai-title` and otherwise fell back to the first
    prompt, so a renamed chat showed the model's name and a chat with only a custom title showed a
    prompt fragment — three of the four newest transcripts on this Mac had no `ai-title` at all.
  - `AgentSessionLogParser.claudeTitle(fromRecordText:)` (new, pure) scans both records from the
    leading and trailing bytes as before and returns the last custom title, else the last AI title;
    `displayChatName` keeps the prompt fallback. Five tests pin the precedence.
  - The tail read escalates through the tail-state reader's windows (16 KB → 256 KB → 1 MB) until a
    chunk carries a title record: a turn's last records are often large tool results, and on this
    Mac the newest title sat 7–31 KB before EOF, so the fixed 16 KB window returned an older copy or
    nothing. The verdict is cached per file against (mtime, size), like the tail state, so quiet
    sessions cost a stat. Verified on the four newest transcripts: all four names now equal Claude's.

### 2026-09-08 - Weekly usage bar takes the freshest reading, not the highest-ranked source
- **Developer label:** also see if there is a regression for 5 hour session bar in claude
- **Agent label:** Merge Claude usage windows per key by newest observation; source order only breaks ties
- **Changes:**
  - The 5-hour bar itself had not regressed: with the real files on this Mac, HEAD's merge ladder
    yields five_hour 11 % from the desktop history with a 13:14 reset, matching the app's own samples
    (0 % right after wake, 11 % fifteen minutes later). What was on screen was an old debug build
    from 2026-09-02 03:41 (`com.kannu.app.dev`, hook script v29, usage script v3, "Session" label,
    codename Fiji) that predates every usage-card change since — replaced by a current dev build.
  - The trace did find a real bug: `ClaudeUsageSnapshot.merged` took each window from the first
    source in which it was live, and "live" only means the reset has not passed. The cache's
    `seven_day` fetched six days earlier (20 %) therefore beat the desktop history's sample from
    thirty minutes earlier (31 %) until the cache lapsed on 09-09. Each key now goes to the source
    with the newest `observedAt`; rank (statusline, cache, desktop) only breaks ties, lapsed copies
    still never win, and output order still follows rank so the gauges do not reshuffle. Three new
    `ClaudeUsageSnapshotTests` cases pin it; the existing rank test already used equal timestamps.

### 2026-09-08 - Warp and Claude Desktop agent mode as sources; tool errors on a red light
- **Developer label:** also just checks its coverage for the agents and see what all we can upgrade for the ones that we cover now; add Warp; does that mean we have way to show errors happening and success-full end
- **Agent label:** Add Warp and Claude Desktop agent mode as passive sources; count tool failures per turn so a stopped light says whether the turn went well
- **Changes:**
  - `WarpAgentStore` (new): passive source over `warp.sqlite` (read-only, WAL honoured — never
    `immutable=1`, the WAL was 173 MB here). `ai_queries.output_status` maps Pending → executing only
    while younger than the 360 s active window *and* Warp is running (stale Pending rows are
    interrupted runs), Completed → stopped, Cancelled → aborted, Failed → stopped with one tool error.
    Newest exchange per conversation; the prompt's first 60 characters name the chat (Warp has no
    titles). 2 s query cache because the WAL fires FSEvents on every write. Warp has no hook API, so
    yellow is never claimed.
  - `ClaudeDesktopAgentSessionStore` (new): passive source over `local-agent-mode-sessions/**/audit.jsonl`
    (interactive `local_<uuid>/`, dispatch `agent/local_ditto_<uuid>/`). `system:init` gives model and
    cwd; the newest conversational record gives the state; `result` `is_error` and `tool_result`
    `is_error` count tool errors per turn; a `rate_limit_event` with status `rejected` →
    `quota_exceeded`. **No utilization percent exists in that payload (verified in CLI 2.1.263), so
    this does not replace `/usage`.** Runtime-unverified: no agent-mode data on this Mac; fixture
    tests only.
  - Turn outcome: hook script v31 (embedded + mirror, byte-identical) counts `PostToolUseFailure` /
    `postToolUseFailure` / `StopFailure` into `tool_errors` (reset on `UserPromptSubmit` /
    `beforeSubmitPrompt`, `is_interrupt` excluded), and the Claude hook table gains
    `PostToolUseFailure`. A red light now reads "Stopped" or "Stopped · N tool errors". Antigravity's
    `Stop` with an `error` counts too. `AgentSessionStatus.toolErrorCount` is additive, so every
    memberwise reconstruction goes through `carryingExtras(from:)` and the reconciler carries it
    across the hook/passive seam (REGRESSIONS entry 7 field set grows).
  - Both new providers get icons, click-through (activate/launch by bundle id; Claude Desktop is
    never handed a folder), a "Detected Editors" entry, a place in the notch's empty state, and
    FSEvents watches on their directories when present.
  - Tests: 1 new hook-script case (payloads now serialized, not hand-written — a raw-string literal
    ending in a quote lost that quote to its terminator and produced invalid JSON), 7 Claude Desktop,
    10 Warp (fixture DB), plus the reconciler's inheritance assertion.

### 2026-09-03 - Sign the release DMG; flag that REGRESSIONS hashes predate the history reset
- **Developer label:** raise pr for this
- **Agent label:** Sign the disk image before notarization; note the 2026-09-03 reset in REGRESSIONS
- **Changes:**
  - `create-dmg.sh` now signs the disk image with a Developer ID identity before it is handed to
    notarization. The app inside was already signed and `notarize-dmg.sh` already staples the ticket,
    but the DMG itself carried no signature at all, so signature-based checks (`spctl -a -t open`,
    some enterprise tooling) reported "no usable signature" on a published build. Signing is optional
    by design: CI has a Developer ID cert in its temporary keychain, a local `build-dmg.sh` run
    usually does not, so the script skips with a notice instead of failing. Order matters and is
    unchanged — sign, then notarize, then staple, which leaves the signature valid.
  - `docs/REGRESSIONS.md` says up front that the commit hashes it cites predate the 2026-09-03
    history reset and no longer resolve in a fresh clone. The rules and guards are unaffected; only
    the provenance links are dead.

### 2026-09-03 - Name releases after watchers; 1.2.0 is Argus
- **Developer label:** avoid atoll style naming and do something else we made first version fiji mistakenly
- **Agent label:** Replace the inherited island codename with a Kannu scheme, shown in About and the release title
- **Changes:**
  - Release codenames now follow a watcher theme, since watching agents is the app's job: Argus for
    1.2.0, then Heimdall, Horus, Vigil, Sentinel. 1.0.0's "Fiji" was the tail of Atoll's island chain
    (Maldives → Bora Bora → Seychelles → Fiji), not a choice; it appeared in no tag, DMG, appcast item
    or release title, so nothing external changes.
  - The name is a plain constant, `ReleaseInfo.codename` in `Constants.swift`, replacing the
    `releaseName` Defaults key that nothing ever wrote (a stored value could have pinned an old name
    for upgraders). Settings › About reads it.
  - Both release paths title the GitHub release `Kannu <version> — <codename>`: `manual-release.sh`
    and the CI release workflow grep the constant, so the codename is bumped in one place. Documented
    in `scripts/RELEASE.md` under "Codenames".

### 2026-09-03 - Wait a beat before a hidden island reacts; stop the closed strip eating clicks
- **Developer label:** only on hover of about 1 full second should reveal the notch, the idea is to not get in the way of actual content below
- **Agent label:** Dwell-gate the hidden-edge hover poll on the existing hover-duration setting; hit-test only the notch shape while closed
- **Changes:**
  - On displays where Kannu hides until hovered, the island no longer slides in the instant the pointer
    touches the top edge. The 50ms poll now keeps a `HoverDwell` (new, Foundation-only, 4 tests) and
    calls the hover-in only once the pointer has rested in the entry rect for `minimumHoverDuration`;
    the open then follows immediately instead of waiting the same interval a second time. Leaving during
    the dwell leaves no trace. The physical notch, region hovers and the agent-activity reveal are
    untouched. Not runtime-verified here (no external display).
  - `minimumHoverDuration` default 0.3s → 1.0s and the Settings slider now spans 0–2s; the row is also
    shown with hover-to-open off when a display hides until hovered, carries a caption explaining the
    slide-in dwell, and is searchable ("dwell", "slide in"). Installs that ever moved the slider keep
    their value; untouched installs get 1.0s for hover-to-open everywhere, by decision.
  - While closed, the shelf drop target (`dragDetector`) no longer backs the whole ≥640×218pt panel:
    it now sits on the notch layout with the notch's own shape, so clicks beside the closed notch reach
    the app beneath instead of Kannu, and it parks off-screen with a hidden island. Open behaviour and
    drop-to-shelf on the notch itself are unchanged. Unverified whether AppKit also swallowed those
    clicks at the window level; if it did, a window-level fix is still needed.

### 2026-09-02 - Tell the user when Claude limits need a CLI sign-in
- **Developer label:** so we need /login in cli always, werent we spinning up gui chat window ?
- **Agent label:** Show a sign-in hint on the Claude card instead of silently falling back to the desktop history
- **Changes:**
  - Clarified which sign-in the usage paths use: Kannu's `/usage` spawn and the statusline both run the
    CLI on its own keychain credentials (`Claude Code-credentials`); sessions inside the desktop app run
    on a host-injected token whose scopes omit `user:profile`, and the CLI's usage fetch returns nothing
    without that scope. One `/login` from a Terminal `claude` (not from a chat inside the desktop app)
    restores it; it is not a recurring step.
  - `ClaudeUsageSnapshot.hint(hooksInstalled:statusline:cache:now:)` (4 tests): when Claude hooks are
    installed and neither server-backed source has a live window, the monitor publishes
    `claudeUsageHint = .signInNeeded` and the Claude card shows one line — "Limits unavailable — in
    Terminal run claude, then /login". Desktop-only users (no hooks) are never nagged; the hint is
    suppressed while a manual fetch is running and clears on the next refresh once the cache is live.

### 2026-09-02 - Merge Claude usage sources per window instead of falling through whole snapshots
- **Developer label:** the fable bar seems to have had some regression. check that
- **Agent label:** Keep a live per-model window when a sibling window in the same source has lapsed; forward severity from the statusline
- **Changes:**
  - Diagnosis first: the "Fable" bar was not a code regression. It exists only in Claude Code's
    `~/.claude.json` usage cache (`limits[]` `weekly_scoped`), every window in that cache lapsed at the
    05:30 IST weekly reset, and the source ladder discarded the whole snapshot for the desktop-history
    file, which carries only the 5-hour and all-models series. The cache cannot refresh on this
    machine because the CLI's usage fetch returns nothing when the OAuth sign-in lacks the
    `user:profile` scope (the same gate leaves the statusline's `rate_limits` null) — `/login` again.
  - `ClaudeUsageSnapshot.merged(_:now:)`: the three sources (statusline file, cache, desktop history)
    are now merged one window key at a time, best source first, taking each key from the first source
    where it is still live. One rolled-over five-hour window no longer takes a live Fable down with it,
    and a lesser source fills only the keys nothing better has. Nil-reset windows keep their "live"
    meaning; severity is never borrowed across sources; `observedAt` is the newest contributing source.
    When nothing is live anywhere the best parsed snapshot is kept so the 600 s re-read gate holds.
    Pinned by 7 tests.
  - Claude statusline script v4 (both copies): forwards a bucket's `severity` when present. The CLI
    (2.1.255) sends none today, so this is forward-compatibility; the migration re-installs the script
    on next launch and keeps any chained user statusLine.
  - The pre-commit hook now checks the usage-script mirror's version marker the way it already checks
    the agent-status one, and new `UsageScriptTests` (3) execute the usage mirror as a subprocess for
    the first time.

### 2026-09-02 - Name the Claude 5-hour bar and keep its countdown live
- **Developer label:** session in claude to be specifically named 5 hour; the time left is wrong
- **Agent label:** Label the five-hour window "5 hour"; tick the countdown and expire windows at render
- **Changes:**
  - The Claude card's five-hour rate-limit bar is titled "5 hour" (was "Session", a bare literal that
    never reached the string catalog); "Weekly" and "All models" now go through `String(localized:)`
    too, and the dead `rateLimitLabel` case agrees.
  - "resets in" is computed as `resetsAt − now` at render, but the view had no clock, so the text only
    moved when something republished — at best the 180s refresh floor, and not at all with no agent on
    screen. The quota body now sits in a one-minute `TimelineView`, and the same tick drops a bar whose
    reset has passed: expiry used to be evaluated only at fetch time, so a window that ran out while
    the tab was open kept its percent with the countdown silently gone until the next admitted refresh.
  - Diagnosed, not changed this round: the "resets 5:30 am" seen was the Weekly window from a 41-hour-old
    `~/.claude.json` cache — `~/.kannu/agent-status/claude-usage.json` has never been written by the
    statusline, and `ClaudeUsageSnapshot.shouldRefresh` does not re-read while no agent is on screen.
    Also the desktop-history fallback returns `nil` for a lapsed derived reset, which renders as live
    with no countdown. Both left as-is by decision.
  - Checked: the notch caffeinate cup never carried a Smart option (five commits, all on this branch;
    `development`/`main` have no caffeinate code), so its absence is not a regression. A cup-click
    popover with a Smart toggle would reuse the clipboard/timer popover pattern — deferred.

### 2026-09-02 - Race-condition pass over PR #20
- **Developer label:** fix everything according to need, avoid regressions and see if something is a specific ask
- **Agent label:** Fix the confirmed races from the PR #20 concurrency review; keep every deliberate behaviour
- **Changes:**
  - The island now reveals on idle → executing and on a permission prompt again. `rescan()` publishes up
    to three `activityPulse` bumps in one turn (session list, traffic light, then the heartbeat) and
    SwiftUI coalesces them into one `onChange`, so the "last bump was a heartbeat" flag answered for the
    heartbeat alone and strict collapse dropped the transition it rode in with. Replaced by
    `AgentActivityPulseLatch` (heartbeat-only *since the observer last consumed*), pinned by 5 tests.
    Strict collapse itself and the 7s hold are unchanged.
  - Hook script v30, both copies (bodies diffed byte-identical after resolving interpolations):
    one directory-wide lock `.kannu-status.lock` replaces the per-conversation locks — those had to be
    unlinked at session end, and unlinking a lock file while another hook has opened but not yet locked
    it hands that hook a lock on a dead inode, so two hooks ran the merge unserialised. The new lock is
    never truncated and never unlinked; legacy per-conversation lock files are still cleaned up.
  - Hook script: the `STATE_PRIORITY` merge, still scoped to one event's parallel group, now also
    carries an `awaiting_input` written by `PermissionRequest` across a lower-priority event inside the
    2s window. Parallel tool calls produce a `PermissionRequest` for one tool and a `PreToolUse` for its
    sibling, and the same-event gate let green overwrite yellow while the prompt was open. Cost: yellow
    can linger up to 2s after approval.
  - New `HookScriptTests` (5) run the mirror script as a subprocess in a throwaway `HOME`: the
    permission/PreToolUse carry inside and outside the window, the carry limited to PermissionRequest,
    session-end cleanup keeping the directory lock, and 20 interleaved rounds with zero lost urgent
    states — the "11/200" harness, finally committed.
  - Kannu takes the same lock (non-blocking) before deleting a hook status file, skipping the delete
    for that cycle if a hook holds it, and stats the file *before* reading it: sampled after the read,
    an atomic replace landing in between paired the new file's mtime with the old contents and
    `removeIfUnchanged` deleted exactly the fresh status it exists to protect.
  - Hook-triggered (50ms) rescans no longer run Cursor's delete-on-no-backing check: that path does not
    invalidate the transcript path cache the way the FSEvents path does, so a brand-new conversation's
    hook file was judged against a listing taken before it existed and deleted milliseconds after the
    hook wrote it. The 30s poll and the FSEvents rescan still delete.
  - `install(.claude)` performs one read-modify-write of `settings.json` for both the hooks and the
    statusLine key instead of three separate passes, each of which re-read the file and could discard a
    write Claude Code made in between. `installClaudeUsageStatusLine()` remains for the version migration.
  - `/usage` spawn: a `process.run()` failure (reachable when Claude Code reaps the version directory
    just resolved) now clears the pty readability handler before the handle is dropped, matching every
    other exit path; and the fetch runs on a GCD worker instead of a detached Task, since ~55s of
    `Thread.sleep` was pinning a cooperative-pool thread.
  - Hide-until-hover displays (code-reviewed and built; not runtime-verified here — no external display):
    the hidden-edge poll keeps running while a hover is latched instead of stopping the moment it
    succeeds, because an island that slides in under a stationary pointer never receives a tracking-area
    exit and `isHovering` stuck true with the island stranded; the poll's exit test gained hysteresis (a
    rect covering the hovered island, its wings and the pill offset) so it can no longer disagree with
    `.onHover` at 20Hz in the band below the entry rect; hover-in no longer cancels the reveal countdown
    (the expiry task already re-arms while hovering, and a cancel with no guaranteed hover-out to re-arm
    it stranded the island); locking the screen now drops hover state and the global click monitor, so a
    click anywhere after unlock no longer opens the notch; region hover cancels the outer hover task so
    the two no longer race to choose the landing tab. Supersedes the earlier "region-hover also cancels
    the reveal countdown" note.
  - `enableMinimalisticUI` sink hops to the main actor like its neighbours instead of resizing the
    window synchronously inside the Defaults setter's stack frame (a SwiftUI update pass when driven by
    a `@Default` binding).
  - `BluetoothAudioManager`: the launch scan on the utility queue no longer reads the battery
    dictionaries the main thread mutates concurrently (device rows are created without battery and the
    cache is warmed via the existing main-hopped write), and its completion merges on address instead of
    overwriting `connectedDevices`, which dropped a device that connected while the scan was in flight.
  - `ClaudeLocalAccountReader` no longer caches a failed parse under the pre-read mtime, which pinned an
    empty account (no tier badge) after a torn read of `~/.claude.json` during Claude Code's rewrite.
  - `HoverTooltip` tracks its 0.4s show as a cancellable work item; an uncancelled timer from an
    earlier hover-in fired early for the next one.
  - Removed `ClaudeQuotaClient.swift`: unreferenced since the statusline path landed, and the only home of
    three latent races (keychain prompt stacking, the interactive cooldown bypass, a late 200 clearing a
    429 backoff). `KeychainReader` stays (Cursor token store). `QuotaAction.grantClaudeKeychainAccess`
    remains declared with nothing producing it — follow-up.
  - Pre-existing, outside the PR diff: the waveform scrubber's 60Hz timer is now a SwiftUI-owned
    `Timer.publish` subscription (the manual timer captured the view and outlived it when `.onDisappear`
    did not fire); `KannuViewModel` sinks receive on `DispatchQueue.main` rather than `RunLoop.main`
    (which stalls in tracking run-loop modes while the resize drain does not), and `open()` lost its
    unreachable `Thread.isMainThread` branch; the notification bridge no longer reports a cancelled
    in-flight send as `lastError`; `NowPlayingController.readData()` cannot leave its continuation
    un-resumed when `close()` wins the race with the readability handler.
  - Reviewed and deliberately left as designed: strict collapse (`physicalNotchAgentBandFollowsHeartbeat`),
    `|| isHovering` in `showAgentTrafficLight`, the `removeIfUnchanged` guard, the 2s merge window and
    never refreshing `ts` on preserve, Cursor-only delete-on-no-backing, the `drainingParkedRequest`
    floor bypass, `hooksOnly` transcript retention, the pure-debounce `scheduleRescan`, and the two
    forced battery refreshes at `checkForNewlyConnectedDevices`/`updateConnectedDevices`.

### 2026-09-01 - Address the open CodeRabbit findings
- **Developer label:** check code rabbit comments in pr #20 and address valid ones
- **Agent label:** Fix the four CodeRabbit findings that verified, reject two
- **Changes:**
  - Hook script v29: coerced the two `existing.get("ts")` reads with `isinstance` before subtracting.
    `or 0` only defaults falsy values, so a truthy non-numeric `ts` raised `TypeError` — and since the
    allow JSON is printed only at the end, with no outer `try` and no `set -e`, the hook died with
    empty stdout and exit 0, leaving the host tool with no permission verdict. Reproduced against the
    pre-fix script (`"ts": "…"` and `"ts": [1]` both produced empty stdout) and confirmed fixed.
    Applied identically to both copies; mirror parity verified by hand, since the pre-commit guard
    compares only version markers and would not catch a body edit.
  - `BluetoothAudioManager` no longer forces a battery cache refresh on the main thread after the
    initial scan. `refreshBatteryLevelsForConnectedDevices` defaults to forcing, which re-ran
    `system_profiler` and `pmset` synchronously — seconds of blocking subprocess work on main,
    immediately after `7b3e290` had moved the IOBluetooth first touch off it. The scan a moment
    earlier already warmed the cache.
  - The deferred window-resize drain reads `pendingWindowResize` at drain time instead of capturing
    it, and an immediate pass clears the queued request. Previously a synchronous resize arriving
    after the re-entrancy guard dropped could be overwritten by the older queued size.
  - Added accessibility labels to the closed-notch traffic light, whose aggregate state was conveyed
    by colour alone and rendered as text nowhere, and to `claudeRefreshButton`, matching the existing
    convention in `KannuHeader`.
  - Declined two findings: `*.profraw` is deliberately unanchored and nothing in the repo enables
    coverage, so anchoring it to the root would narrow the pattern for no benefit (the misleading
    comment is reworded instead); and the `claudeLimitsToggle` label targets a control deleted in
    `4e85ff7`.


### 2026-09-01 - Hold the notch reveal for 7 seconds instead of 5
- **Developer label:** for any transition state traffic light disappears in 5 seconds, make that 7 seconds
- **Agent label:** Raise the reveal window to 7 seconds
- **Changes:**
  - `notchRevealHoldSeconds` is now 7. Five seconds was too short to catch an agent state change you
    were not already looking at — the heartbeat is filtered out by strict collapse, so only real
    transitions arm the window and a missed one is missed entirely until the next transition.
  - The constant is deliberately shared, so the hover-exit linger and the notch-close re-arm lengthen
    with it; the hover mechanics themselves are untouched. Its doc comment is updated in the same
    edit so it no longer claims the window is 5.


### 2026-09-01 - Regression guards for the usage spawn and notch tooltips
- **Developer label:** add test cases and doc md files to avoid such regressions
- **Agent label:** Guard the usage-fetch invocation and the notch tooltip rules
- **Changes:**
  - Extracted the Claude `/usage` spawn decisions into a pure `ClaudeUsageFetchCommand` and covered
    them with `ClaudeUsageFetchCommandTests`, pinning that no attempt carries a `--print`-only flag,
    that the environment stays plain inheritance, and that the last attempt stays bare.
  - Added pre-commit guards rejecting `.help(...)` in notch views and the `fixedSize(horizontal:)`
    shape that silently collapses every tooltip.
  - Added `docs/TOOLTIPS.md` explaining why `.help(...)` cannot render in an accessory app with a
    non-activating panel, plus the layout rules for `hoverTooltip`.
  - Added `docs/REGRESSIONS.md` entries 8 and 9 for both failure classes.
  - Converted all eight dead `.help(...)` tooltips in the notch to the shared `HoverTooltip`
    component, with the caffeinate controls opening downward so the `ScrollView` no longer clips them.
  - Reinstated the interactive `/usage` spawn behind the Claude card's refresh button
    (`refreshClaudeUsageFromCLI`), reverting the 2026-08-30 "honest reload" entry below. `/usage` is
    declared `requires: {ink}` and cannot run in `--print` mode, so a disk-only reload can never move
    the per-model weekly window — the button would spin and change nothing. The tooltip is back to
    "Fetch latest usage (runs /usage)". Known residual: only the first attempt carries
    `--settings {"disableRemoteControl":true}`, so the bare fallback can still register a
    remote-control device (the "phantom chat"); `disableRemoteControl` appears to be managed-only.
  - Fixed a SIGPIPE bug in `.githooks/pre-commit` that meant the changelog check never actually ran.
    Both changelog `awk` passes exited on their terminating line while `printf` was still writing the
    ~78 KB `[Unreleased]` section; `printf` took SIGPIPE and `pipefail`+`errexit` aborted the hook
    with exit 141 before any check executed. Both now read to EOF and gate on a flag.
  - Renumbered the two `docs/REGRESSIONS.md` entries that were both numbered 7; the file now runs
    1-9 with the danger-zone cross-reference corrected.
  - Removed the dangling `"Show Claude usage"` Settings search entry, whose row and
    `enableClaudeUsageDisplay` key were deleted in `4e85ff7` — searching for it scrolled to a row
    that no longer exists. Its quota keywords are folded into the live `Claude Provider` entry so
    the search stays useful.
  - Replaced `.github/assets/kannu-logo.png`, which was still the **Atoll** app icon under a Kannu
    filename, with the real mark from `AppIcon.appiconset` (1.9 MB to 36 KB). Deleted
    `kannu-colorpicker.png` (a feature this fork removed) and the unreferenced `iosdevcentre.jpeg`.
    Known follow-up: 20 of the remaining 21 files in `.github/assets/` are still unreferenced by any
    tracked file — most are usable product screenshots that simply are not linked from the README.

### 2026-08-30 - Shorten the refresh button tooltip

- **Developer label:** trim the claudeRefreshButton .help() text
- **Agent label:** The refresh button's hover tooltip is now one short line
- **Changes:**
  - The hover tooltip on the usage refresh button was a long two-clause sentence. Shortened to
    "Reload usage. Run /usage in Claude Code to refresh Fable." — same meaning, glanceable

### 2026-08-30 - Make the usage refresh button an honest reload

- **Developer label:** drop the spawn entirely; button re-reads from disk; help text states the /usage requirement
- **Agent label:** The refresh button no longer spawns anything — it reloads, and says how to refresh Fable
- **Changes:**
  - `/usage` — the only command that fetches the per-model (Fable) weekly window — requires Claude
    Code's interactive TUI (`requires: {ink}` in the command definition). Headless `--print` has no
    TUI, so it cannot run `/usage` and cannot fetch Fable; the interactive session that can is exactly
    what registers the remote-control device (the phantom chat). There is therefore no way for Kannu
    to fetch fresh Fable without that side effect
  - So the button no longer spawns anything. It re-reads `~/.claude.json` (and the other sources) on
    press, picking up whatever the user's own `/usage` last wrote, and its help text says plainly:
    *"Reloads your usage from disk. The per-model weekly limit (e.g. Fable) only refreshes when you
    run /usage in Claude Code — it needs the interactive session."* No spawn, no chat, no keychain,
    no token cost, no misleading "fetches" claim
  - Removed the now-dead spawn machinery (`runUsageFetch`, `resolveClaudeBinary`, the pty/SIGKILL
    handling and the in-flight flag)

### 2026-08-30 - Refresh usage headlessly so it never registers a device/chat

- **Developer label:** replace the interactive pty spawn with `claude --print --no-session-persistence`
- **Agent label:** The refresh button no longer creates a phantom Claude session or sign-in warning
- **Changes:**
  - The refresh button spawned `claude` **interactively**, and an interactive session auto-registers
    as a remote-control device on the account — a phantom chat (auto-named, e.g.
    `…-keen-wozniak`) plus a new-device "sign in" prompt. Neither was a real conversation or an auth
    break (verified: `oauthAccount` and keychain intact), but both are noise the user should never see
  - The spawn is now headless: `claude --print --no-session-persistence "/usage"`, with
    `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` in the child env. Print mode is one-shot and registers
    no device, so no chat and no sign-in prompt. Confirmed live: a press created no new session
  - No pty any more — a plain `Process` with drained pipes, the same poll-the-fetch-stamp completion
    signal, the SIGKILL escalation, and reap-before-exit. The button also re-reads `~/.claude.json`
    on every press regardless, so it always refreshes the displayed value from disk

### 2026-08-30 - Harden the usage refresh from the ART review

- **Developer label:** guaranteed SIGKILL escalation on the spawn; single shared usage-load ladder
- **Agent label:** The refresh button can't get stuck, and the fallback logic lives in one place
- **Changes:**
  - **Refresh button could latch disabled.** `runUsageFetch` sent SIGTERM then `waitUntilExit()`, but
    the interactive CLI under a pty can trap SIGTERM — `waitUntilExit()` would then block the detached
    task forever and the spinner flag (`isRefreshingClaudeUsage`) would never clear, leaving the
    button dead for the session. It now escalates to SIGKILL after a short grace, so exit is
    guaranteed and the flag always resets
  - **One usage-load ladder, not two.** The statusline → cached → desktop-history fallback was written
    identically in both `refreshClaudeUsage(now:)` and `reloadClaudeUsageNow()`. Extracted to a single
    `loadClaudeUsageSnapshot(now:)`, so a fourth source can never be added to one caller and forgotten
    in the other

### 2026-08-30 - Make the usage refresh exit on success, and fix a crash it could cause

- **Developer label:** wait for the cache stamp instead of the timeout; reap the process before any terminationStatus read
- **Agent label:** The refresh button is quicker and no longer able to crash the app
- **Changes:**
  - **Crash fix.** `Process.terminationStatus` raises an ObjC exception when the process has not
    exited, and `terminate()` only sends SIGTERM without waiting — so reading the status on the
    timeout path aborted the app (`SIGABRT`, `Kannu-2026-08-30-194649.ips`). Swift cannot catch an
    ObjC exception, so this was fatal every time the fetch hit its ceiling. The process is now reaped
    with `waitUntilExit()` and no live status read remains anywhere in that path
  - **Exits on success rather than on timeout.** Claude Code writes the refreshed usage into
    `~/.claude.json`, so that file's fetch stamp is the completion signal: the spawn now polls it and
    stops the moment it advances. A press costs a few seconds instead of always burning the full
    ceiling and dying by signal (`exit=143`). The ceiling remains, purely as a backstop for a wedged
    CLI
  - Verified live end to end: a press advanced the fetch stamp and moved the session and weekly
    figures (9%→19%, 68%→69%) against the server, with no crash, no leaked child process and no
    stray files

### 2026-08-30 - Redesign the usage card and add a one-tap CLI usage refresh

- **Developer label:** grouped Session/Weekly sections, severity-driven accents, pty-based /usage refresh button
- **Agent label:** The usage card is cleaner, and a button pulls your latest usage including the per-model weekly limit
- **Changes:**
  - The three rate-limit bars are grouped into **Session** and **Weekly** sections. The word
    "Weekly" and the reset countdown appear once per section instead of on every bar — the weekly
    windows genuinely share one reset, so repeating it was noise. Per-model bars sit under the
    Weekly header labelled by model name ("All models", "Fable")
  - Bar accents now come from the server's own `severity` field (`normal`/`warning`/`critical`)
    when present, falling back to the previous fraction bands for sources that do not report it.
    A window at its cap (e.g. Fable at 93%, critical) reads red because the server says so
  - `severity` is threaded from `ClaudeCachedUsage` through `UsageLimit`/`NamedLimit` to the view.
    The fixed windows borrow their severity from the parallel `limits[]` array, which carries it
    keyed by kind (`session`/`weekly_all`)
  - New **refresh button** top-right of the Claude card, with help text. It triggers Claude Code's
    own `/usage` fetch — the only local source of the per-model weekly window — by running the
    installed CLI under a pseudo-terminal (the slash command needs an interactive session; headless
    `-p` treats it as prompt text). It uses the credential Claude already stored: silent after a
    one-time keychain "Always Allow", reads only limit metadata, and costs no tokens. Kannu never
    sees the credential — the CLI writes `~/.claude.json`, Kannu re-reads it
  - Race-free by construction: the spawned process only writes a file; the single cached snapshot is
    still written on the main actor alone, and an in-flight guard prevents overlapping spawns. The
    binary path resolves to the newest installed version, surviving updates
  - `KannuTests`: per-model and fixed-window severity parsing. Suite is now 128

### 2026-08-30 - Remove the vestigial gauge toggle from the Claude card

- **Developer label:** drop claudeLimitsToggle, its @Default and the enableClaudeUsageDisplay key
- **Agent label:** One less control on the usage card; the rate-limit bars just show
- **Changes:**
  - The gauge icon in the Claude card header existed because the 5h/7d limits once needed a network
    call and a one-time keychain approval, and the control was deliberately placed on the card so
    that cost sat next to the benefit. Its own comment still said so. That path was removed earlier —
    every number now comes off disk — so the justification for the unusual placement went with it,
    leaving an ordinary show/hide toggle in prime space on a status card
  - It was also the only control for `enableClaudeUsageDisplay`, a preference with no Settings row,
    which is backwards. Rather than relocate a toggle nobody needs, the control and the key are both
    gone: the bars render whenever a source supplies them, governed by the staleness rules already in
    `ClaudeUsageSnapshot`. A stale value left in user defaults is inert once nothing reads it
  - `import Defaults` dropped from `ClaudeUsageProvider`, which no longer reads any default

### 2026-08-30 - Fix pale caffeinate toggle when the notch opens inactive

- **Developer label:** custom capsule toggle replaces NSSwitch; literal sparkle colors
- **Agent label:** The caffeinate switch is orange the moment the notch opens, not only after you click it
- **Changes:**
  - `.toggleStyle(.switch)` is a real NSSwitch, and NSSwitch draws its ON tint only while its window is key and the app active — this LSUIElement app's non-activating notch panel is neither on a hover-open, so an ON switch rendered desaturated gray until the first click made the panel key. Replaced with a custom capsule toggle in `NotchAgentStatusView` that draws its orange fill from SwiftUI state directly, immune to key-window status; same footprint, accessibility label/value/toggle trait preserved
  - Smart-mode sparkle's off-state color switched from `Color.accentColor` (`controlAccentColor`, documented to render gray while the app is inactive) to a literal color for the same reason

### 2026-08-30 - Read Claude's own cached usage, including the per-model weekly bars

- **Developer label:** new ClaudeCachedUsage source reading ~/.claude.json cachedUsageUtilization; three-source precedence
- **Agent label:** The Usage tab can now show the per-model weekly bar Claude Code shows in /usage
- **Changes:**
  - Claude Code caches its `/api/oauth/usage` response in `~/.claude.json` under
    `cachedUsageUtilization`, and that cache is the only local source carrying **per-model weekly
    windows**. The statusline hook can deliver them as `rate_limits.model_scoped`, but only while a
    session drives it; the desktop app's history file discards them before writing. Reading the cache
    needs no credentials and makes no network call
  - Per-model entries are selected exactly as Claude Code selects them for its own display:
    `kind == "weekly_scoped"` with a `scope.model.display_name`, rendered under that server-supplied
    name. The window keeps **its own denominator** — it is never derived from the all-models weekly
    figure, which it can sit well above or below
  - Fixed windows here report `utilization`, not `used_percentage`, and `resets_at` is an ISO 8601
    string with microseconds rather than epoch seconds. Both are handled; an unparseable timestamp
    costs the countdown, never the bar. `cinder_cove` is carried generically like any other window
  - The cache is rejected outright when its `accountUuid` does not match the signed-in account,
    mirroring Claude Code's own guard, so another login's numbers can never be shown
  - Source precedence is now statusline hook, then this cache, then the desktop history — each
    falling through when absent or empty. The cache outranks the history because it carries real
    reset times where the history forces them to be inferred from rollovers
  - New `scripts/kannu-fable-usage.sh`: standalone `jq` extractor for the same value, for use outside
    the app. Reads only the usage keys, prints `null` rather than a fabricated value when no such
    quota exists, and takes an optional model name (defaulting to whatever is on the account's
    overage-included allowlist)
  - `KannuTests`: per-model parsing and its independent denominator, microsecond and plain ISO
    timestamps, unparseable dates, non-scoped kinds ignored, `utilization` vs `used_percentage`,
    account mismatch rejected, and every empty or malformed shape returning nil. Suite is now 126

### 2026-08-30 - Reset countdowns on the desktop-history path

- **Developer label:** recover window boundaries from rollovers in plan-usage-history; countdown format reworked
- **Agent label:** Both usage bars now show time remaining, not just a percentage
- **Changes:**
  - The gauges only ever showed a countdown when the statusline hook supplied `resets_at`. The desktop
    history fallback records `{t, org, u}` and no reset times at all, so anyone on that path — which
    is anyone who has not signed the CLI in — saw bare percentages
  - The boundaries are recoverable from the history itself, because a rollover shows up as a drop in
    utilization: the running window began at the most recent one and ends a window-length later,
    5 hours or 7 days taken from the window's own name rather than fitted to the curve
  - A rollover is a decrease of more than 5 points, **or** any decrease landing on zero. Both clauses
    earn their place against real data: the 5-hour window is rolling, so it also sheds a point or two
    as old usage ages out and those decays must not count; but three genuine rollovers in the sample
    history are `1 -> 0`, `4 -> 0` and `5 -> 0`, which a drop-size threshold alone would miss
  - A derived reset is used **only if it lands in the future**. Sampling happens only while the app
    runs, so a rollover is noticed minutes after the fact and the derived time errs late — the safe
    direction, since `displayWindows` hides any window already past its reset. If a derivation is
    wrong or the history is stale, the window loses its countdown rather than disappearing
  - Countdowns now read `2d 22h 37m` over a day, `4h 56m` under one, and `56m` under an hour. The
    previous format switched to days only past 69 hours and appended seconds under an hour, which is
    noise on a gauge read at a glance
  - `KannuTests`: both window lengths, decay-not-rollover, a two-point drop to zero that is one, a
    past reset being dropped while the bar survives, and a history with no rollover at all. Suite is
    now 114

### 2026-08-30 - Add the weekly per-model bar (Fable)

- **Developer label:** forward `rate_limits.model_scoped` from the statusline hook; windows carry a server-supplied label
- **Agent label:** The weekly Fable limit now has its own bar
- **Changes:**
  - The per-model weekly window is not a fixed key, which is why widening the key list last time still
    did not surface it. Claude Code's own statusLine schema (binary 2.1.247) delivers it as
    `rate_limits.model_scoped`: an array of `{display_name, utilization, resets_at}`, documented as
    "per-model weekly windows from the server limits[] array" and "additive — present only when the
    server emits them", with `'Fable'` as the schema's own example label. The earlier search looked at
    the desktop app bundle, whose fixed key list has no Fable entry and never will
  - The statusline script (now `KANNU_USAGE_SCRIPT_VERSION=3`) walks that array alongside the fixed
    windows. It normalises the two differences on the way through — the value is `utilization` rather
    than `used_percentage`, and `resets_at` is an ISO 8601 string rather than epoch seconds — so Kannu
    reads one shape. The block is guarded: nothing in this newer, optional field can cost us the
    universal 5-hour and weekly windows
  - Windows now carry an optional `label`. Where the server named a window, that name is used;
    where it did not, the existing key-derived name still applies. So the bar reads "Weekly (Fable)"
    because the server said Fable, not because Kannu guessed a key
  - `KannuTests`: label round-trip, ordering after the two universal windows, empty and absent labels,
    and an expired model-scoped window being hidden. Suite is now 109

### 2026-08-30 - Correct the usage bars, and stop recomputing them every second

- **Developer label:** open-ended rate-limit windows, desktop-history fallback, cached 10-minute refresh
- **Agent label:** The usage bars are named for what they actually measure, and they fill in even without the statusline hook
- **Changes:**
  - **The bars were mislabelled.** They read "Session" and "Week" while the same card listed token
    totals also called "Session" and "Week" — two meanings, same words. They are rate-limit windows,
    so they now read "5-hour session" and "Weekly (all models)". The token rows are unchanged
  - **There is no per-model Fable window; the assumption was wrong.** Claude's own bundle carries the
    full key list — `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`,
    `seven_day_cowork`, `seven_day_oauth_apps`, `seven_day_omelette`, `omelette_promotional` — and
    Fable usage rolls into `seven_day`. Rather than hardcode a guess, the statusline script (now
    `KANNU_USAGE_SCRIPT_VERSION=2`) forwards **every** `rate_limits` key, `ClaudeUsageSnapshot`
    carries them as a list instead of two fixed pairs, and any window beyond the universal two
    renders as its own gauge labelled from its key. A window Anthropic adds shows up without a code
    change; previously it was silently dropped
  - `ClaudeUsageSnapshot.parse` still reads the old flat `five_hour_pct` shape, so the gauges do not
    blank out between the app upgrading and the next statusline write
  - **New fallback source: the Claude desktop app's own history.** It records a sample every few
    minutes into `~/Library/Application Support/Claude/plan-usage-history.json` (30-day retention),
    which needs no hook and no credentials — so the bars now populate even for someone who only ever
    runs Claude in the desktop app, where the statusline command may never fire. The hook stays
    primary because it alone reports reset times. `xu` is excluded deliberately: it tracks
    extra-usage spend, not a rate limit, and would be a lie as a gauge
  - **The values are cached instead of recomputed.** `refreshClaudeUsage` ran at the end of every
    `rescan()` — a file read and JSON parse every second — to feed a published property that, after
    the agent-card copy was removed, had no consumers at all. It now re-reads at most once per 10
    minutes and only while an agent is on screen, with one unconditional read so the card is
    populated when opened cold. `ClaudeUsageProvider` reads that cache rather than the file, so
    there is one reader on one cadence instead of two on two. The interval matches reality: neither
    source updates faster than every few minutes
  - `KannuTests`: 22 tests across `ClaudeUsageSnapshotTests` and new `ClaudeDesktopUsageHistoryTests`
    — window-list and legacy parsing, malformed entries, display ordering, expired extra windows,
    short-code mapping, `xu` exclusion, and the refresh-cadence boundaries. Suite is now 57
  - Merging this onto the branch retired the credential path's leftovers: the gauge button on the
    Claude card now toggles `enableClaudeUsageDisplay` (the key that still gates anything) instead of
    the dead `enableClaudeUsageLimits`, which is deleted, and its help text no longer promises a
    keychain prompt that cannot happen. The Usage settings footer described that same removed flow at
    length; it now says what actually happens, in three sentences instead of six

### 2026-08-29 - Claude 5h/7d usage display in the notch
- **Developer label:** statusLine-fed rate-limit usage snapshot, gauges under agent cards
- **Agent label:** The notch now shows Claude Code's real session and weekly usage
- **Changes:**
  - New Kannu-managed statusline script `~/.claude/kannu-usage-status.sh` (embedded in `AgentHookInstaller`, mirror in `scripts/`, versioned `KANNU_USAGE_SCRIPT_VERSION=1`): reads Claude Code's statusLine stdin JSON, writes `rate_limits.five_hour`/`seven_day` (`used_percentage` 0-100, `resets_at` epoch seconds — server-reported via `anthropic-ratelimit-unified-*` response headers) atomically to `~/.kannu/agent-status/claude-usage.json`, then chains the user's original statusLine command (preserved base64 in the script, restored verbatim on uninstall)
  - Installed with the Claude hook (`install(.claude)`), removed on uninstall, and backfilled for existing installs via `migrateClaudeUsageStatusLineIfNeeded`
  - New pure `ClaudeUsageSnapshot` (parse + staleness rules): fresh under 10 minutes, dimmed with relative age after, and a window whose reset time has passed is hidden (its percentage is stale fiction). `CursorAgentStatusMonitor` publishes it from the existing status-directory watcher — no new watcher
  - The gauges render in the **Usage tab**: `ClaudeUsageProvider` maps the snapshot onto the existing `sessionLimit`/`weekLimit`, so `NotchLLMUsageView`'s established quota gauges and reset countdowns display it with no new UI. Gated by new `enableClaudeUsageDisplay` default (on) with settings row + search entry. An earlier draft put a second copy under the agent session cards; usage lives on one surface, and that one was below the fold in a scroll view
  - **The credential path is gone.** `ClaudeUsageProvider` no longer calls `ClaudeQuotaClient`, so there is no keychain read, no OAuth request, and no recurrence of the permanent `Claude login found but unreadable` error the card used to show. Claude Code hands the numbers to the statusline for free; reading credentials to ask a server for what is already on stdin was the wrong trade. `ClaudeQuotaClient`/`KeychainReader` remain on disk, now unreferenced
  - Fixed a SIGABRT crash while in here: `Kannu-2026-08-29-234024.ips` was an uncaught AppKit exception in `_postWindowNeedsUpdateConstraints`, reached from `NSHostingView.invalidateSafeAreaCornerInsets`. CLAUDE.md documents the cause (`sizingOptions` unset) but the invariant held in only **1 of 25** hosting views; all 16 sites hosted in borderless panels now set `sizingOptions = []`. The five hosting views in normal windows keep content-driven sizing deliberately
  - `parseHookSessions` GC is safe by construction: `claude-usage.json` has no `state` key, so the session parser skips it before any delete branch
  - `KannuTests`: `ClaudeUsageSnapshotTests` covering parsing, partial windows, freshness boundary, and expired-window hiding
### 2026-08-29 - Fix the color picker failing to compile on CI's toolchain
- **Developer label:** Explicit CGFloat/Double conversions in ColorSpectrumPicker; hue stops as a literal array instead of a computed stride
- **Agent label:** Same behavior, now builds everywhere
- **Changes:**
  - The new spectrum picker compiled locally but failed CI with "ambiguous use of operator '/'": it leaned on implicit CGFloat/Double bridging that the newer local toolchain resolves and CI's does not. Every conversion between the pure math layer (Double) and SwiftUI geometry (CGFloat) is now explicit, and the hue gradient uses an explicit stops array rather than a computed stride. No behavior change

### 2026-08-29 - One shared color layer, with a working in-app gradient picker
- **Developer label:** New Kannu/components/Color (KannuColorSwatch, KannuColorSwatchGrid, ColorSpectrumPicker, KannuColorPickerButton) + ColorSpectrumMath with 10 tests; both settings and agent pickers rebuilt on it; NSColorPanel path deleted
- **Agent label:** Custom colors finally work, and every color control in the app is now the same component
- **Changes:**
  - "Custom…" never worked because it opened `NSColorPanel`, which is unreliable in this accessory (menu-bar) app — the app's own code has warned about exactly that for a while. Custom colors are now picked in-app with a gradient picker: a saturation/brightness plane, a hue slider and a hex field (`#1E90FF` and `#FFF` shorthand both accepted; invalid input reverts instead of applying garbage). No dependency on the system panel remains
  - The app had two hand-copied swatch-popover implementations — one for the settings color rows, one for the agent traffic-light palette — plus two different luminance formulas deciding the same "is this swatch light?" question. There is now a single shared color layer under `Kannu/components/Color/`, and both pickers are built on it, so circle sizes, borders, checkmarks and contrast can no longer drift apart. The duplicate formula is deleted; contrast comes from the existing `Color.contrastingForeground`
  - The palette's rule that two agent states can never share a color is now expressed as a `disabledReason` on the shared grid rather than reimplemented per picker, so it is enforced in one place
  - Drag geometry and hex conversion live in a pure, Foundation-only `ColorSpectrumMath` pinned by 10 tests (edge clamping, plane round-trips, shorthand expansion, rejection of malformed input) — the parts that otherwise fail silently. Suite is 84

### 2026-08-29 - Fix "Show Colors…" doing nothing in the settings color picker
- **Developer label:** ColorPanelPresenter owns NSColorPanel and NSColorSampler; the popover's hosted NSColorWell is gone
- **Agent label:** The Custom option now actually opens the full color panel
- **Changes:**
  - Regression from the color-picker rebuild: the popover hosted an `NSColorWell`, and macOS's "Show Colors…" opens `NSColorPanel`, which takes key window status and dismisses the transient SwiftUI popover — destroying the hosted well and its target/action, so the panel led nowhere. The popover now shows a plain "Custom…" button that dismisses itself and hands off to a persistent presenter which owns the panel, seeds it with the current color, and writes changes straight back to the setting
  - Same class of bug fixed pre-emptively for the eyedropper: `NSColorSampler` was created inline and could be released before the user picked, dropping its completion. The presenter holds it for the duration of the pick
  - `ColorWellSwatch` and `WheelColorWell` are removed — nothing referenced them once the well left the popover

### 2026-08-29 - Launch at login on by default, and it now stays on
- **Developer label:** One-time auto-register gated by didAutoEnableLaunchAtLogin; stale-path repair replaces the every-launch unregister/re-register; requiresApproval surfaced in Settings; LoginItemPolicy + 9 tests
- **Agent label:** Kannu starts itself at login, and switching it off in Settings sticks
- **Changes:**
  - A fresh install in /Applications now registers Kannu as a login item once, on first launch, so an ambient monitor is actually running when you log in. Strictly one-time: `didAutoEnableLaunchAtLogin` guarantees that turning the Settings toggle off keeps it off forever — the app never re-enables behind the user's back
  - Fixed a real reliability bug: the app unregistered and re-registered the login item on *every* launch, so a single transient `register()` failure silently lost launch-at-login for good (and the teardown was redundant — the package's setter already re-registers). Repair now runs only when the bundle path actually changed, i.e. after a genuine move or reinstall, and never turns a disabled item back on
  - Registration outcomes were completely invisible. There is now a `LaunchAtLogin` log category recording the auto-enable, the repair and the resulting `SMAppService` status, and the Settings row surfaces the `requiresApproval` case with a button that opens Login Items instead of a toggle that silently reads off
  - The Settings toggle remains authoritative throughout: it reflects live OS state, not a stored flag. `LoginItemPolicyTests` (9 tests) pins the two rules that matter — never auto-enable twice, never repair an unchanged path. Suite is 74

### 2026-08-27 - Claude session limits actually work now, with a local 5-hour block fallback
- **Developer label:** enableClaudeUsageLimits defaults on; interactive enable + floor bypass + card-never-vanishes; per-window tolerant decode; ClaudeSessionBlocks (ccusage-style) + Session (local) row; quota-debug gaps closed; 7 tests
- **Agent label:** The 5h/7d gauges appear by default, the approval button works, and when the server can't be reached you still get tokens-this-block and a reset countdown
- **Changes:**
  - Root cause of "session limit detection doesn't work": `enableClaudeUsageLimits` defaulted to false and had never been enabled — the quota client had literally never run (the debug log showed only clean refreshes and nothing else, because the short-circuit logged nothing; it does now). Research verdict recorded: the 5h/7d utilization percentages exist only at the authenticated `/api/oauth/usage` endpoint (statusline stdin, transcripts, telemetry and `~/.claude.json` all verifiably lack them), and the client already sends the right headers including the community-required User-Agent
  - The enable flow had three traps, all fixed: the gauge toggle refreshed without `interactive` so the keychain prompt could never appear; the "Show usage limits" button press was silently swallowed by the 10-second refresh floor (interactive taps now always pass); and auth-failure states could hide the whole card, stranding the user — a card carrying a fix-it button or an explanatory message now always stays visible
  - The response decode was all-or-nothing: one omitted `resets_at` (seen on idle windows of this undocumented endpoint) threw the whole response away and killed BOTH gauges. Windows now decode independently and tolerate missing fields, degrading one gauge instead of both
  - New local fallback, honest by design: `ClaudeSessionBlocks` reconstructs the current 5-hour block from the transcripts Kannu already parses (anchor = first request after the previous block, floored to the hour — the ccusage convention) and the card shows "Session (local)": tokens this block plus the reset countdown, whenever the server gauge is unavailable. Deliberately not a percentage: the plan's budget and Anthropic's weighted utilization only exist server-side, and local sums are documented to diverge
  - `enableClaudeUsageLimits` now defaults to true — the gauges are the point of the card; the fetch stays cooldown-protected and the keychain read stays behind the explicit approval button. 7 new block-reconstruction tests; suite is 65

### 2026-08-27 - Record the sign-last install trap
- **Developer label:** CLAUDE.md: test builds with CODE_SIGNING_ALLOWED=NO stomp the identity-signed product
- **Agent label:** The install pipeline signs last, or TCC grants silently die again
- **Changes:**
  - Found while proving grant durability: running the unit tests (which build with signing disabled) after the identity-signed build overwrites the product with an unsigned one, so installing afterward ships an ad-hoc app and every TCC grant misses again. The recipe now says: signed build last, verify `codesign -dr-` shows `certificate leaf` before copying

### 2026-08-27 - Crafted palette values for the traffic-light colors
- **Developer label:** Tailwind-derived 400/500 hexes replace plain system colors in AgentTrafficLightPaletteColor; enum cases and stored selections unchanged
- **Agent label:** The swatches stop looking flat on the dark notch
- **Changes:**
  - The 10 palette hues now use hand-picked Tailwind-derived values chosen for vivid rendering on the dark notch and mutual distinctness at dot size (e.g. a deeper go-green, an icy mint, a cyan-leaning teal). Raw values and names are untouched, so saved selections keep working with zero migration; the three defaults' hand-tuned neon panel values are preserved exactly

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
