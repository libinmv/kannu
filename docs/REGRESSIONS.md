# Regressions and the invariants that keep breaking

Kannu's agent-status subsystem has a memory problem: the same handful of rules get
re-broken by well-intentioned changes, because the rule lives in someone's head (or in a
comment nobody re-reads) rather than in something that fails.

This file is the ledger. Every entry is a rule that has **actually broken more than once**,
with the commits to prove it. It is not a style guide and not a wish list — if an entry
here has never cost a real bug, delete it.

**Read this before touching anything under `Kannu/managers/AgentStatus/`.**

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

**Guard — exists.** `.githooks/pre-commit` compares the two version markers and rejects the
commit on mismatch. Regenerate the mirror from the embedded literal rather than hand-editing
it; hand-editing is how `quota_exceeded` had to be typed into both copies separately
(`817f114`).

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
trades one wrong colour for another. Fix the state machine, not the clock.

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

**Guard — missing.** A test asserting the four path sets are equal per provider would be
cheap and would have caught both occurrences.

---

## Danger zones

Commit counts across all branches (`--follow`, so pre-rename history counts):

| File | Commits | What edits here have historically broken |
|---|---|---|
| `CursorAgentStatusMonitor.swift` | 18 | The merge/reconcile seam. **Every** edit is chat-name resolution, hook-vs-transcript precedence, or session deletion/ageing. Entries 5 and 6 live here. |
| `AgentTrafficLightState.swift` | 18 | The state ladder — staleness thresholds and verdict→colour mapping. Mostly *tuning numbers*, which is exactly how entry 2 happened. |
| `AgentHookInstaller.swift` | 17 | Embedded script + event table + install/uninstall/migration. Grows monotonically; every growth episode has broken `checkInstalled` or a migration (entries 1 and 6). |
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
