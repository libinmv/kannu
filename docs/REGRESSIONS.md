# Regressions and the invariants that keep breaking

Kannu's agent-status subsystem has a memory problem: the same handful of rules get
re-broken by well-intentioned changes, because the rule lives in someone's head (or in a
comment nobody re-reads) rather than in something that fails.

This file is the ledger. Every entry is a rule that has **actually broken more than once**,
with the commits to prove it. It is not a style guide and not a wish list — if an entry
here has never cost a real bug, delete it.

**Read this before touching anything under `Kannu/managers/AgentStatus/`.**

> **The commit hashes cited below predate the 2026-09-03 history reset.** `main` was rebuilt that
> day on a new root commit, so those hashes do not resolve in a fresh clone — they survive only in
> archived copies of the pre-reset history. Every rule, failure mode and guard described here is
> unaffected; treat the hashes as provenance for the story, not as something you can `git show`.

---

## How to use this

- **Before editing** a file listed in [Danger zones](#danger-zones), read the entries that
  reference it.
- **When a bug recurs**, add an entry — the second occurrence is the signal, not the tenth.
- **Prefer a guard to a paragraph.** Every invariant below that broke *after* being written
  down proves prose alone does not hold. Where a mechanical check is cheap, it is listed
  under **Guard** and it exists; where it is missing, the entry says so.

---

## 1. The hook script mirror must match the embedded copy

**Rule:** `AgentHookInstaller.swift` embeds the authoritative hook script.
`scripts/kannu-agent-status.sh` is a generated mirror. They must always carry the same
`KANNU_HOOK_SCRIPT_VERSION`.

**Broken 3 times.** Drifted at `80ce9e1` (2026-08-06, v24 vs v23) → resynced `709457e`
(2026-08-09) → drifted again (v26 vs v25) → resynced `fe12f7d` (2026-08-19) → **drifted a
third time on `development`** and was still drifted when this file was written (v24 vs v23).

**Why it keeps happening:** two copies of one artifact, and only one of them is exercised by
the app. The embedded copy is what the app installs and what every developer tests; the
mirror is what `scripts/install-cursor-hooks.sh` hands to users. Nothing links them, so the
mirror rots invisibly.

**What it cost:** between 2026-08-06 and 2026-08-19, a user who installed Cursor hooks via
the script got a version without the `flock` serialisation and without the atomic
temp-then-`os.replace` write — the exact races later measured at 11/200 lost urgent states
and 14/4825 torn reads.

**Guard — exists.** `.githooks/pre-commit` compares the two version markers and, since v34, the
bodies too (the embedded literal de-indented by 8 spaces, the marker interpolation substituted,
against the mirror byte for byte) — a body edit without a matching copy fails the commit.
`HookScriptTests.testEmbeddedScriptMatchesTheMirror` runs the same comparison in CI.

**v34 addendum — no backslash in the Python.** The embedded copy is a plain Swift string literal:
`"\n"` in the Python becomes a real newline in the installed script, `"\U000E0000"` does not
compile, and escaping them makes the two copies differ. Build code points and regex character
classes with `chr()` (the hidden-text scan does exactly that). The pre-commit hook and the same
test reject any backslash in the mirror's Python body. v35 keeps to it: the secret patterns use
lookarounds and character classes, not `\b`, and check the "no word character before" edge in code
(a leading lookbehind also made a 1 MB scan 40 times slower — a regex that starts with its literal
lets the engine skip ahead). Before this guard existed, the rule was: diff
the two Python bodies (extract each heredoc, strip the embedded copy's 8-space indent) and expect
byte identity. Regenerate the mirror from the embedded literal
rather than hand-editing it; hand-editing is how `quota_exceeded` had to be typed into both copies
separately (`817f114`). Since v30, `KannuTests/HookScriptTests.swift` executes the mirror as a
subprocess and pins the merge and lock behaviour, so a behavioural drift in the mirror fails CI even
when the markers agree. The Claude statusline script (`writeUsageScript` ↔
`scripts/kannu-usage-status.sh`, `KANNU_USAGE_SCRIPT_VERSION`) has the same two-copy shape; since v4
the pre-commit hook checks its markers too and `KannuTests/UsageScriptTests.swift` executes its mirror.

---

## 2. The active-state staleness window must exceed the longest tool call

**Rule:** `activeStaleMs` / `runningStaleSeconds` = 360s. Do not shorten it.

**Broken once, and the break was subtle.** 360s from `511e33b` → dropped to **15s** by
`709457e` (2026-08-09, titled "green traffic light lingering during idle time") → restored
by `817f114` (2026-08-18) after review caught it.

**Why it keeps happening:** it looks like a tuning knob for a false-*green* complaint. It is
actually the thing preventing a false-*red* for every hook-only provider. Codex, VS Code and
Antigravity write **no status file at all during a tool call** — the file is silent for the
tool's entire duration. A 15s window marks any tool call longer than 15 seconds as stopped.

**The deeper lesson:** the real cause of that false-green was elsewhere (transcript tail
parsing, `80ce9e1`; the demotion arm, `24b2ef2`). Shortening a timeout to fix a state bug
trades one wrong colour for another. Fix the state machine, not the clock. (Entry 12 is the
same lesson on the yellow light: its clock became the only exit, and a true yellow died on it.)

**Guard — exists.** `RegressionGuardTests.testHookOnlyProviderMidToolCallStaysActiveAt*`.
Verified to fail when the default is set back to `15_000`.

---

## 3. `.unknown` on a live process means working, never idle

**Rule:** when the transcript tail cannot be parsed but the process is alive, map to a
working state.

**Flipped 3 times, fixed twice independently.** `80ce9e1` → idle. `f46a323` (2026-08-18,
antigravity branch) → thinking. `24b2ef2` (2026-08-21, development) → idle again, in a
newly-written function. `397743d` → thinking.

**Why it keeps happening:** "unknown" reads like "nothing is happening", so idle feels like
the safe default. It is the opposite. `.unknown` is only reachable for a process that is
demonstrably *running*, and once the reconciler's demote arm began consuming passive
verdicts, a single unreadable read could dim a correctly-green session.

Round 3 was not a fresh mistake — it was the same wrong default re-derived on a branch that
never received the first fix. See [Merge hygiene](#merge-hygiene).

**Guard — exists.** `PassiveClaudeStateTests.testUnknownWithQuietFileStaysThinking`.
**This test must survive the `feat/antigravity-integration` merge.**

---

## 4. A truncated tail must widen the window, never report `.unknown`

**Rule:** when a read window yields no verdict, escalate to the next window. A failed read
says nothing about the wider ones — their byte offsets are different.

**Broken by the commit that stated it.** `24b2ef2` introduced both the doc comment ("a
truncated tail must widen rather than report `.unknown`") and an escalation loop that
`break`-ed on a nil read. Since `readTrailingLines` seeks to an arbitrary byte offset and
decoded strictly, any window boundary landing inside a multi-byte character (em dashes,
arrows, emoji — ubiquitous in transcripts) abandoned escalation entirely. Fixed `397743d`,
one day later.

**Why it keeps happening:** the comment and the code were written in the same commit and
still disagreed. Nothing checks a comment against its implementation.

**Guard — exists.** `AgentSessionLogParserTests.testEscalationSurvivesMultibyteWindowBoundary`
builds a fixture that deliberately straddles a character on the boundary; verified to fail
against the pre-fix reader.

---

## 5. A chat title must never be resolved against itself, and must never become "Untitled chat"

**Rule:** the display name comes from the log-derived title (`ai-title`, transcript title)
when one exists. Never a raw prompt, never a bare tool name, never a fallback when a real
name is available on another session record.

**Broken 5 times** — `04ec047` (2026-07-12), `ae6151f` (07-16), `e6d9abb` (07-20),
`8caf98d` (07-20), `f46a323` (2026-08-18). Four are explicitly framed as regressions.

Two distinct failure shapes recur:
- **Self-comparison.** `8caf98d`: both resolvers vetted a candidate title against
  `sources.logTitles[sessionID]` — which is where the candidate came from — so every real
  title was rejected as "unreliable". The warning comment from that fix is still in
  `CursorAgentStatusMonitor.swift` and is worth reading before touching the vetting logic.
- **Name not carried across the merge seam.** `f46a323`: a repaired hook session did not
  inherit the passive session's name, and `hasHookSessionBacking` deleted claude/codex hook
  files whenever the transcript listing missed — welding "no name yet" to "delete the
  session".

**Why it keeps happening:** name resolution spans four sources (hook payload, transcript
title, composer metadata, passive session) merged in a ~200-line private method. Every new
provider adds a path through it.

**Guard — partial.** `RegressionGuardTests.testToolNamesAreRejectedAsChatTitles` and
`testRealChatTitlesSurviveSanitation` pin `AgentApprovalGatedTools.looksLikeToolName`, the
primitive both resolvers share.

**Gap:** `resolveHookProviderChatName` and `resolveCursorChatName` are `private` on
`CursorAgentStatusMonitor`, which the logic-only test target does not compile — so the
self-comparison bug itself is still untestable. Closing it means lifting those resolvers
into a pure, testable type (as `looksLikeToolName` already was). **This is the
highest-value missing test in the repo** — five regressions, no coverage.

---

## 6. Migration coverage must equal install coverage must equal uninstall coverage

**Rule:** whatever set of paths `install` writes, `checkInstalled`, the version migration,
and `uninstall` must all cover the same set.

**Broken twice.** `80ce9e1` established it for Claude ("growing the hook table would make
existing installs report 'not installed' and skip their own upgrade"). `1cc631c` re-broke it
for Antigravity: the migration inspected only the IDE config, which install touches only
when it already exists, so a fresh install was never migrated. Uninstall had the mirror-image
bug — it stripped fewer locations than install wrote, leaving entries pointing at a deleted
script while `checkInstalled` still reported installed.

**Why it keeps happening:** the four path sets are written independently in four places, and
adding a provider means remembering all four.

**Guard — exists (2026-09-11).** The four sets are one now: `AgentHookLayout` lists each
provider's script and every settings file its entries can be in, with the file's shape and
whether install always writes it or only merges into it when present. `install` (the Antigravity
merge), `uninstall` (every listed file, whatever the write policy), `checkInstalled` (any listed
file with the required entries), `stripEntries` (routed by the listed shape), and the version,
legacy-script and event-argument migrations all read it. `AgentHookLayoutTests` pins the table
(a script per provider, an always-written file per provider, one owner per file) and fails if a
hook path literal reappears in `AgentHookInstaller.swift` code. A new provider is one more case in
the layout.

---

## 7. A hook session shadows the passive session — carry everything across

**Rule:** when a hook session and a passive session describe the same conversation, the hook
one wins the display slot. Anything the passive side knows and the hook payload does not must
be copied across in the reconciler, or it is lost for every hook-tracked session.

**Broken 3 times, in two different fields.**

| # | Field lost | Symptom | Commits |
|---|---|---|---|
| 1-2 | `chatName` / `projectName` | every hook-tracked Claude session rendered "Untitled chat" | `8caf98d` (2026-07-20), `f46a323` (2026-08-18) |
| 3 | `hostPID` / `cwd` | click-through silently inert — no hand cursor, no tooltip, dead click | shipped in `ff2caab`, fixed here |

**Why it keeps happening:** the hook payload is structurally thinner than the passive
session — no title, no pid — and the shadowing is invisible at the call site. A field added
to `AgentSessionStatus` is wired through ~14 construction sites and *still* silently dropped
here unless the reconciler's inheritance helper is updated too. The third occurrence happened
in the same helper that had just been written to fix the first two.

**How occurrence 3 evaded verification:** the feature was tested against a passive-only
session (no hook file), which carries its own `hostPID` and worked correctly. Sessions *with*
hook files — the normal case — were broken the whole time. Measured on the live machine:
3 of 4 displayed Claude sessions had `hostPID = nil` before the fix; the fourth was the one
without a hook file.

**Guard — exists (2026-08-26).** The reconciler was lifted verbatim into
`AgentTrafficLightMapper.reconcileClaudeSessions(...)` (pure, Foundation-only, in the logic
test target). `ClaudeReconcilerTests.testInheritedFieldsCarryAcrossOnDemote` and
`...OnUnchangedSession` pin all four inherited fields — verified by temporarily dropping the
`hostPID` inheritance and watching both tests fail. Entry 5's name-resolution half is NOT
covered by this: the resolvers still span filesystem/SQLite sources inside the monitor and
remain untestable until they grow a seam.

**Still true:** when you add a field to `AgentSessionStatus` that a passive session can
populate, add it to `inheritingPassiveData` (now in `AgentTrafficLightState.swift`) AND to
the field assertions in `ClaudeReconcilerTests` in the same commit. The field set as of
2026-09-10: `chatName`, `projectName`, `cwd`, `hostPID`, `desktopSessionID` (Claude Desktop's own
id for the chat, the click-through locator — carried by `carryingExtras` as `self ?? source`;
guards: `ClaudeReconcilerTests.testDesktopSessionIDCarriesAcrossBothReconcilerArms`,
`ClaudeDesktopSessionIndexTests.testDesktopSessionIDSurvivesReconstruction`, the retention test).

**2026-09-08 addendum — additive fields.** `toolErrorCount` and `isUnattended` are `var`s with
defaults, so the memberwise initialiser compiles happily without them and *silently drops them*
at every one of the ~14 reconstruction sites. The rule: any `AgentSessionStatus(...)` built from
another session ends in `.carryingExtras(from:)` (max of the two counts, OR of the flags);
`inheritingPassiveData` calls it too. Guard: `ClaudeReconcilerTests` asserts both survive the
demote path and `AgentSecurityFindingTests.testUnattendedFlagSurvivesReconstruction` covers the
three helper initialisers. When you add another additive field, extend `carryingExtras`, not the
call sites.

**2026-09-11 addendum — `hiddenText`.** Hook-only sightings of hidden Unicode (hook v34). They ride
`carryingExtras` as a set union keyed by (kind, location, first seen) — the newer copy of one sighting
wins, the newest three are kept, empty is the identity — never a replace, or a reconstruction from a
side that has not seen the sighting would erase it. Guards: `ClaudeReconcilerTests` (demote and
pass-through arms carry it) and `HiddenTextIncidentTests.testReconstructionHelpersKeepTheField`.
Since the sightings refactor the field is `sightings` (`HookSightings`, one list per hook-side check)
and the union is `HookSighting.union` per list; a new check adds a list to `HookSightings`, never a
new field on `AgentSessionStatus`. v35 adds `secrets` and `sensitivePaths` that way, plus one
locator, `terminal` (the hook-reported tty, session leader and its start time), carried like
`desktopSessionID` as `self ?? source`. Guard: `HookSightingsTests.testTerminalLocatorRidesTheSeamAsSelfOrSource`.

**2026-09-09 addendum — the run verdict is not additive.** `runError` (why the run ended, nil for
a clean finish) is a per-turn *verdict*, replaced by every stopped write. It rides the same
`carryingExtras` seam but merges as `RunError.preferred` — `self` unless it has none, then the more
specific reason — never as an OR or a max: under those nil is the identity, so one stale verdict
would pin "failed" onto every later clean turn. The only things that may set it are run-terminating
signals (hook `ended_on_error`, the transcript's `isApiErrorMessage`, Warp `Failed`, Desktop
`result.is_error`); `toolErrorCount` is a count of recovered failures and must never become one.
Guards: `ClaudeReconcilerTests.testRunVerdictSeamPrefersTheHookThenTheMoreSpecificReason`,
`RunErrorTests`, and the hook-script cases that pin a recovered or trailing tool failure as clean.

---

## 8. Never add a flag or env var to the usage spawn without proving a real fetch

**Rule:** the Claude usage fetch invocation is verified empirically, not reasoned about. Every
argument and environment variable must be confirmed against an actual `fetchedAtMs` advance before it
ships.

**Broken twice in one day**, both by additions that looked defensive and harmless:

- `--no-session-persistence` — valid only with `--print`. The interactive session `/usage` requires
  exited immediately ("can only be used with --print mode"), so the command was typed into a dead
  process. Symptom: spinner ran, nothing fetched, no error surfaced.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` — added as "belt-and-braces" against bridge traffic.
  It suppresses nonessential network traffic, and the usage fetch **is** a network call to
  `/api/oauth/usage`. Symptom: identical — session started, `/usage` ran, cache never updated.

**Why it keeps happening:** the failure is silent and looks like success. The session starts, the
spinner spins, the process exits cleanly, and the only signal that anything went wrong is a
timestamp on disk that did not move. Nothing in the UI or logs says "the fetch was suppressed".

**Guard — exists.** `ClaudeUsageFetchCommand` holds the invocation as data, and
`KannuTests/ClaudeUsageFetchCommandTests.swift` pins: no print-only flag in any attempt, the
environment is plain inheritance (`nil`), the forbidden env key is recorded, and the **last attempt
stays bare** — that bare invocation is the one observed to actually fetch. Both regressions were
verified to turn the suite red before this was committed.

---

**2026-09-10 addendum.** The ADR Detection run (`uv run --project <checkout> python
<adapter> …`) is pinned the same way: `ADRDetectionCommand` holds the arguments and the
environment whitelist as data, `ADRDetectionCommandTests` pins both, and the embedded adapter is
tested identical to `scripts/adr-analyze-session.py`. Permission and tool flags never pass
through Kannu — the adapter alone decides how upstream runs its Claude session.

## 9. Notch tooltips are custom; `.help()` is dead there

**Rule:** never use SwiftUI `.help(...)` under `Kannu/components/Notch/` or
`Kannu/components/AgentStatus/`. Use `.hoverTooltip(...)`.

**Broken across 8 call sites**, all shipped and none ever rendering: `KannuHeader`, `NotchNotesView`
(x2), `NotchTimerView`, `NotchAgentStatusView` (x4). Then broken three more times while fixing it —
a competing `.onHover` shadowing the tooltip, `fixedSize(horizontal:)` collapsing the bubble to the
parent's width, and a `ScrollView` clipping a bubble that opened upward from its first row.

**Why it keeps happening:** `.help()` is the obvious, correct-looking API and fails **silently** —
it compiles, reads fine in review, and simply never appears. AppKit only shows tooltips for the
active application, and this accessory app with a non-activating panel is never active. Nothing in
the type system or the build says so.

**Guard — exists.** `.githooks/pre-commit` rejects any `.help(` in those directories, requires
`HoverTooltip.swift` to keep a bare `.fixedSize()`, and rejects `fixedSize(horizontal:)` there.
The layout rules that cannot be grepped — `edge` versus container clipping, one hover source per
control — are written up in **docs/TOOLTIPS.md** with the reasoning and a checklist.

**Gap:** none of this is unit-testable; a new tooltip still has to be hovered in a real build.

---

## 10. Never derive observer semantics from the *last* `@Published` bump

**Rule:** a `@Published` counter can be bumped several times in one main-actor turn, and SwiftUI
delivers them as a single `onChange`. Any side flag the observer reads must describe the whole
window since it last looked, never the most recent publish.

**Broken once, on the commit that introduced the flag** — `32c260b` (2026-08-26) added
`lastPulseWasHeartbeat` with a doc comment asserting it was "read synchronously by the pulse
observer (same main-actor turn as the publish)". It was not: `rescan()` bumps `activityPulse` for
the session list, again for the traffic light, and last for the heartbeat, so the observer saw
one change and a flag that said "heartbeat". Strict collapse then swallowed every idle → executing
and every permission prompt — the reveal the 7s hold (`d3d056a`) was raised to serve. Listed
despite a single occurrence because the false premise was written down as fact in the code and
survived two review passes.

**Why it keeps happening:** the publish and the observation feel synchronous when you read the
code top to bottom; nothing at the call site says "coalesced".

**Guard — exists.** `AgentActivityPulseLatch` (in `AgentTrafficLightState.swift`, logic target)
is the only source of the verdict and is pinned by `AgentActivityPulseLatchTests`. Keep the
heartbeat emit last in `rescan()` — it reads the state `applyDisplay` just wrote — and keep
exactly one consumer of the latch.

---

## 11. A passive source never does its I/O on the main actor

**What happened (2026-09-09).** `WarpAgentStore.sessions` opened `warp.sqlite` synchronously
inside `rescan()`. The database lives in Warp's *group container*, and the first `open()` of another
app's container raises the macOS "access data from other apps" prompt — `open()` blocks until the
user answers. Every launch that morning froze the whole app (timers, hovers, the notch) for as long
as the dialog stayed up, and killing the app to rebuild dismissed the dialog unanswered, so the next
launch prompted again. `sample` showed 100 % of main-thread samples in `guarded_open_np`.

**The rule.** Reads of anything under `~/Library/Group Containers`, `~/Library/Containers`, Desktop,
Documents, Downloads, or any other TCC-protected path run on a worker queue, one at a time, with the
result handed to the main actor (`refreshWarpExchangesIfNeeded` is the shape: a cached result the
rescan maps, a refresh that schedules the next rescan only when the result changed). Same rule for
any new passive source. CLAUDE.md's "first touches of protected resources" trap is this rule stated
for `AppDelegate.init`; it applies to every later touch too.

**Guard.** `WarpAgentStoreTests.testSessionsFromExchangesNeedNoDatabase` pins the pure mapping, so
the split cannot quietly grow a file read again.

**2026-09-10 addendum.** The same shape now reads Claude Desktop's session index
(`ClaudeDesktopSessionIndex.Loader` on a utility worker, `refreshDesktopSessionIndexIfNeeded`):
not for TCC — `~/Library/Application Support/Claude` is not protected — but because the records
are 100+ KB each and rewritten on every Desktop turn. Only the reduced id map crosses back, and
it is compared as a map so a timestamp bump alone never schedules a rescan.

## 13. A live Claude session is never resumed

**Rule:** `claude://resume?session=<id>` imports a transcript into Claude Desktop and starts a new
`claude --resume` host for it. On a session whose process is still alive that is a second consumer
of the same transcript. Only a chat whose process is gone may be resumed, and only once its card is
dim. A live chat goes to its terminal, its tmux pane, or nowhere.

**What happened (2026-09-11).** The opener's own header already said "never resume a live
session", but the Claude arm resumed any `.inactive` card that had no reachable host. A live but
idle session in tmux (whose server's parent is launchd), `screen` or ssh has a `hostPID` and no GUI
app up its parent chain, and its dim card read as "not running" — so a click spawned a duplicate.

**Guard.** The decision moved into `AgentClickThroughPolicy` (logic target);
`AgentClickThroughPolicyTests.testInactiveLiveSessionNeverResumes` and
`…testLiveSessionWithoutAHostNeverResumes` pin it. A live process is "live" by `hostPID` today;
anything that later proves liveness (a hook-reported terminal) must feed the same flag.

## 12. Yellow follows evidence, not the clock

**Rule:** an `awaiting_input` hook state expires on the 300 s clock (`awaitingInputStaleMs`) only
when nothing can say whether the prompt is still open. Where liveness evidence exists — a live
Claude process whose transcript tail still shows the `tool_use` with no result, a Cursor transcript
with a pending approval — the yellow and, for Claude, its hook file live as long as the evidence
does. Yellow still *originates* from hooks only; evidence corroborates, never claims.

**What happened (2026-09-10).** A Claude Code prompt left unanswered went dark at 5 minutes and,
at 30, handed the card to the passive twin as a dim "inactive" chat (or green, when the pending
`tool_use` read as a running tool). Every earlier yellow fix had made the clock stricter: the
2026-08-06 sticky-latch fix stopped refreshing `ts` "so the 5-minute escape can still fire", and
the parallel-group merge preserved `ts` again — after which the clock was yellow's only exit.
Nobody asked whether a *true* yellow could outlive it.

**How it works now.** `buildClaudeSessions` runs before `parseHookSessions` and hands over
`liveTailByConversationID`; the parser computes `holdsAwaitingInput` per file, passes
`holdAwaitingInput:` to `resolveHookState`, and exempts a corroborated Claude prompt from the stale
deletion (`awaitingInputOutlivesStaleCap`). Hook-only providers (vscode/codex/antigravity, and since v36 copilot/gemini/qwen/opencode — a new
hook-only provider must join this list or its yellow dies at 5 minutes) hold on
display and keep the stale cap — it is the end of their yellow. Claude's `idle_prompt`, a dead
process and Cursor's sticky yellow without an approval stay on the clock. Caffeinate keeps its own
5-minute bound (`awaitingInputCaffeinateSeconds` + the `awaiting window` recheck), so a held
yellow cannot keep the Mac awake all night.

**Guards.** `RegressionGuardTests.testHeldAwaitingInputStaysYellowAtOneHour`,
`…testUnheldAwaitingInputExpiresAfterFiveMinutes`, `…testAwaitingInputHoldFollowsEvidencePerProvider`,
`…testOnlyACorroboratedClaudePromptOutlivesTheStaleCap`;
`ClaudeReconcilerTests.testHeldYellowSurvivesPassiveToolInFlight`, `…testHeldYellowDemotesWhenTheProcessDies`,
`…testAgedYellowIsNotPromotedByPassiveActivity`; `CaffeinateDecisionTests` window and recheck cases.
**Missing:** the monitor-side ordering and the deletion exemption are not reachable from the logic
target — manual check: the waiting session's file survives past 30 min in `~/.kannu/agent-status`.

**Never** fix a false yellow by shortening `awaitingInputStaleMs` or by refreshing `ts` in the
script. Add or remove evidence.

## Danger zones

Commit counts across all branches (`--follow`, so pre-rename history counts):

| File | Commits | What edits here have historically broken |
|---|---|---|
| `CursorAgentStatusMonitor.swift` | 18 | The merge/reconcile seam. **Every** edit is chat-name resolution, hook-vs-transcript precedence, or session deletion/ageing. Entries 5 and 6 live here. |
| `AgentTrafficLightState.swift` | 18 | The state ladder — staleness thresholds and verdict→colour mapping. Mostly *tuning numbers*, which is exactly how entry 2 happened, and how the yellow clock became its only exit (entry 12). |
| `AgentHookInstaller.swift` | 17 | Embedded script + event table + install/uninstall/migration. Grows monotonically; every growth episode has broken `checkInstalled` or a migration (entries 1 and 6). |
| `CursorAgentStatusMonitor.swift` (usage spawn) | — | The `/usage` fetch invocation. Two silent breakages in one day from added flags/env (entry 8). |
| `AgentSessionLogParser.swift` | 8 | `readTrailingLines` and the tail verdict. 4 of 8 commits touch the reader; **2 of those 4 fix the same failure mode** — the reader returning nil and silently sending callers down a wrong path (entry 4). |

If you are changing a *constant* in `AgentTrafficLightState.swift`, assume it is load-bearing
for a provider you are not testing.

---

## Merge hygiene

`development` and `feat/antigravity-integration` diverged at `dc39f4f` and ran 3 vs 23
commits apart, with disjoint CHANGELOG sets. That divergence directly caused:

- **The same fix paid for twice** — `.unknown` → working (entry 3) and the lossy UTF-8
  decode were each derived independently on both branches.
- **A commit spent purely on merge shape** — `6fea023` exists only to rewrite a helper back
  into an inline expression so it was *textually* identical to the other branch, because a
  divergent-but-equivalent fix had turned a no-op merge into a conflicted file. Its message
  states the risk plainly: that file carries two fixes, so a mis-resolved conflict silently
  reintroduces a bug.
- **Known bugs deliberately left unfixed** — `817f114` declined to fix two real bugs to
  avoid creating a conflict.

**Practices that follow from this:**

1. When fixing something that also exists on the other branch, **match the other branch's
   text exactly**, even if you would write it differently. Equivalent-but-different is worse
   than either version.
2. Before merging, run the conflict forecast and look at *which* files conflict:
   ```
   git merge-tree --write-tree --name-only --messages development origin/feat/antigravity-integration
   ```
   A conflict in `AgentStatus/` is a hazard, not a chore — resolve it by hand, never with
   `-X ours` / `-X theirs`.
3. Check whether a fix needs to land on both branches *at the time you write it*, not at
   merge time.

---

## Adding an entry

Add one when a bug recurs. Keep the shape: **Rule** (imperative, one line) → **Broken N
times** (with hashes) → **Why it keeps happening** (the structural cause, not the symptom) →
**Guard** (the check that catches it, or an honest "missing").

An entry without commit hashes is an opinion. An entry whose guard says "missing" is a to-do
list item, and that is fine — naming the gap is more useful than pretending it is covered.
