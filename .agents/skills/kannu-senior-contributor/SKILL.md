---
name: kannu-senior-contributor
description: Enforce the Kannu repository workflow and coding standards from CONTRIBUTING.md, including matching existing Swift/SwiftUI conventions, committing CHANGELOG.md entries with developer and agent feature labels, setting up git hooks, and managing PRs.
---

# Kannu Senior Contributor

Kannu is a small macOS Dynamic Island app (Swift/SwiftUI, Xcode 15+). The `CONTRIBUTING.md` defines a specific workflow — this skill exists so that workflow is actually followed, not just referenced. The two failure modes it's built to prevent are the same two that hit any project with a documented process: code that ignores the codebase's existing conventions, and a commit that ships without its changelog entry.

## Before writing any code

The `CONTRIBUTING.md`'s coding guideline is short but load-bearing: *match existing style, extend existing abstractions rather than duplicating logic, keep changes scoped.* That's not fillable from general Swift knowledge — it requires actually looking.

1. **Find nearest sibling files**: Find the nearest sibling file(s) to what you're changing (same feature area, same layer — e.g. another `View`, another `ViewModel`, another manager class) and read them before writing anything.
2. **Match existing patterns**: Match what you find:
   - Naming (e.g. `AgentStatManager` vs `agent_stat_manager`)
   - Property wrapper choices (`@State` vs `@StateObject` vs `@ObservedObject`)
   - How views are decomposed
   - How the Dynamic Island's expanded/compact/minimal presentations are structured
   - Error handling style
   - File organization
3. **Explicitly flag new patterns**: If you're about to introduce a new pattern (a new state-management approach, a new folder structure, a new dependency) rather than extend an existing one, say so explicitly and flag it — don't silently introduce it. This project has one clear convention-setter (the existing code), not a style guide to negotiate with.
4. **Keep changes strictly scoped**: Keep the change scoped to the task. Resist drive-by refactors of adjacent code even if they're tempting — `CONTRIBUTING.md`'s "keep PRs focused" starts at the code level, not just the PR description.

*Fallback*: If no reasonable sibling file exists (genuinely new subsystem), default to standard Swift API Design Guidelines and idiomatic SwiftUI — but note that you did, so the human can confirm it's the direction they want.

## The commit checklist

`CONTRIBUTING.md` requires this before every commit, and it's easy to let slip because it's metadata, not code. Handle it proactively rather than waiting to be asked:

1. **Developer feature label**: A short phrase for what was built, e.g. `Dynamic Island expanded-state layout`. Not a commit message; a stable label a human would use to refer to the feature in a standup.
2. **Agent feature label**: Only if an agent (Claude, another AI tool) did some or all of the work. Same style, but describing the agent's slice, e.g. `Claude: SwiftUI view scaffolding`. Omit entirely for pure human commits.
3. **One `CHANGELOG.md` entry**: Under `## [Unreleased]`, in this shape:

   ```markdown
   ### Developer label: <developer feature label>
   ### Agent label: <agent feature label, or omit this line if none>
   - Changes:
     - <change 1, one bullet per discrete change>
     - <change 2>
   ```

   Keep each bullet to one actual change — don't collapse three changes into one run-on bullet, and don't split one change into three bullets to look thorough.

4. **Stage `CHANGELOG.md` with code changes**: In the same commit, not a follow-up.
5. **Commit subject reflects the developer feature label**: Not `Fixes` or `Updates`. Derive the subject from the label rather than describing the diff mechanically: the label describes intent, the subject should read the same way.

### When asked to "prepare a commit" or "write the commit message"

Do all four artifacts together as one deliverable, since they're derived from the same underlying feature label and should read consistently:

```
**Developer label:** <label>
**Agent label:** <label, or "none — human-authored">

**CHANGELOG.md entry** (add under ## [Unreleased]):
### Developer label: <label>
### Agent label: <label>
- Changes:
  - ...

**Commit message:**
<subject line derived from the label>

<body, if the change needs more explanation than the subject carries>
```

Then remind the user to stage `CHANGELOG.md` alongside the code — don't stage or commit anything yourself unless explicitly asked to run the git commands.

## Git hooks

If a fresh clone or missing-hooks situation comes up, point to `./scripts/install-git-hooks.sh` (run once after cloning) rather than hand-rolling a pre-commit hook — the repo already manages one under `.githooks/`.

## Pull requests

- Target `development` unless the user says a maintainer asked for a different base.
- One feature or fix per PR — if a change grew to cover two unrelated things while you were working on it, flag the split rather than bundling it.
- If the change affects user-facing behavior, note that `ReadMe.md`, localized strings, or inline help text need a matching update — don't let the code ship ahead of the docs that describe it.
- Suggest a PR title/description derived from the same developer feature label used in the commit checklist, so the label stays the throughline from commit to changelog to PR.

## What this skill does not cover

It doesn't replace human testing on real hardware (the `CONTRIBUTING.md`'s dev requirements call for a MacBook with a notch for full feature testing) — flag when a change needs that kind of verification rather than asserting it's been done.
