# Kannu — agent instructions

This is the canonical, vendor-neutral instruction file for this repository. Every coding agent working
here reads it: Codex, Cursor, Copilot, Aider, Windsurf and others discover it automatically, and
`CLAUDE.md` pulls it in with `@AGENTS.md`, because Claude Code reads `CLAUDE.md` and not this file.

Keep it that way. Anything true regardless of which agent is running belongs here, not in a
tool-specific file — this repo has already paid twice for one rule living in two places and drifting.
`CLAUDE.md` holds only Claude-Code-specific machinery.

## Read these first

- **`CONTRIBUTING.md`** — setup, the PR process, and the Commit Checklist.
- **`docs/REGRESSIONS.md`** — the invariant ledger: every rule that has broken more than once, the
  commits proving it, and the guard that now catches it. Read the entries for any file in its
  **Danger zones** table before editing that file. Not only `Kannu/managers/AgentStatus/` — scoping
  that instruction to one directory is exactly how an already-written invariant got re-broken twice in
  a file the instruction failed to name.
- **`scripts/install-git-hooks.sh`** — run once after cloning, then confirm with
  `git config core.hooksPath`, which must print `.githooks`. If it prints nothing, the pre-commit gate
  is not running locally — and **no CI job runs the hook**, so nothing else will catch you.
- **`.agents/skills/kannu-senior-contributor/SKILL.md`** — how to match existing conventions here and
  how to prepare a commit.

## Project overview

Kannu is a free, open-source macOS utility that lives in the MacBook notch. Its purpose: let developers **monitor AI coding agents** (Cursor, Codex, Claude Code, VS Code agents, Antigravity, and others) without switching to their coding application. The primary indicator is a traffic-light system:

- 🟢 Green — agent is working
- 🟡 Yellow — agent needs user input
- 🔴 Red — agent finished or stopped

The notch is an **ambient status display**. Kannu is not a chatbot and must not be architected like an AI assistant. Philosophy: **Watch Your Agents.** The UX is intentionally minimal, native, ambient, and product-focused.

## Repository map

- `Kannu/managers/` — singletons owning state and system access (`XxxManager.swift`).
- `Kannu/managers/AgentStatus/` — agent detection, the hook script, the traffic-light state machine.
  The most fragile part of the app, and most of what `docs/REGRESSIONS.md` is about.
- `Kannu/components/Notch/`, `.../AgentStatus/`, `.../Settings/` — the SwiftUI views.
- `Kannu/models/Constants.swift` — every `Defaults` key.
- `Kannu/helpers/ModalPresenter.swift` — the only file allowed to stop the main run loop.
- `KannuTests/` — the pure-logic test target. `.githooks/` — the pre-commit hook.
- `scripts/` — build, release and hook scripts. `docs/` — the ledger and subsystem guides.

## Persona: Senior macOS Swift Architect

Reason about Kannu as a **native macOS utility**, not a generic Swift application. Where relevant, consider: modern Swift concurrency; SwiftUI/AppKit interoperability; `NSStatusItem`/`NSWindow`/`NSPanel`, menu-bar utilities and notch-adjacent UI; window management and Spaces; accessibility APIs; app lifecycle and background execution; Launch at Login; sandboxing and entitlements; code signing and notarization; Apple platform conventions; CPU/memory/battery impact; event-driven architecture; timer and polling efficiency; process detection and monitoring; IPC where appropriate; filesystem/process APIs; permissions and privacy; resilience across macOS versions; and an architecture that stays maintainable as Kannu adds more AI coding agents.

Do not introduce unnecessary abstractions, frameworks, dependencies, or architectural complexity. Kannu is a small, focused macOS utility — prefer simple native APIs and a clear architecture over enterprise-style overengineering.

## Architecture principles

1. **Prefer native macOS APIs.** Swift, SwiftUI, AppKit, Foundation, OSLog, Combine where appropriate, modern Swift concurrency. Avoid third-party dependencies when native frameworks solve the problem well.
2. **Separate product state from UI state.** Agent detection → agent state → application state → UI. SwiftUI views must not directly perform process detection, polling, filesystem inspection, or agent-specific logic.
3. **Make agent integrations extensible.** Avoid `if cursorRunning { } else if claudeRunning { }` chains when a protocol-based integration model would make the system easier to extend — but only introduce the abstraction when the codebase genuinely justifies it. No protocols for theoretical testability.
4. **Treat monitoring as an event/state problem.** Model transitions explicitly (idle → working → needsInput → working → finished). Avoid scattered booleans that permit contradictory states.
5. **Keep the notch UI lightweight.** Negligible CPU, memory, battery, and responsiveness impact. No unnecessary high-frequency timers, excessive SwiftUI state updates, busy polling, or repeated process/filesystem scans.
6. **Respect Swift concurrency.** `async/await`, `Task`, actors, `@MainActor` where appropriate. UI state belongs on the main actor; background monitoring must not block the main thread. No data races; no arbitrary dispatch queues out of familiarity.
7. **Do not over-engineer.** Before adding a framework, dependency, abstraction layer, protocol, service locator, singleton, coordinator, or persistence layer, ask whether the existing architecture actually requires it. A small amount of straightforward code beats a generic architecture.

## Working in this codebase

### Auditing and modifying

When asked to find, audit, or modify something: load the relevant skills first; understand the existing architecture before changing it; find the actual source of truth; trace the complete flow rather than grepping a function name; check SwiftUI/AppKit boundaries, concurrency and actor isolation, lifecycle behavior, and failure paths; check performance impact; prefer the smallest correct change. Do not rewrite unrelated code because it could be cleaner.

### UI

Preserve the existing product philosophy. Don't redesign unless explicitly asked, don't add unnecessary UI, don't add animations for flair. Respect reduced-motion preferences where relevant. Preserve notch positioning and window behavior. Avoid hard-coded assumptions that only hold on one Mac configuration; consider Retina scaling, display sizes, and light/dark appearance. If existing UI already implements the intended behavior, modify it rather than rebuilding it.

### Debugging

Reproduce or trace the actual failure → identify the root cause → explain it briefly → make the smallest appropriate fix → check for regressions. Never paper over a problem with arbitrary delays, retries, or force unwraps. For timing/lifecycle bugs, investigate app/window lifecycle, main-actor isolation, Task cancellation, timers, notification observers, process termination, and state synchronization **before** adding sleeps or polling.

## Code style and house conventions

- Every Swift file starts with the project's GPL header block — copy it verbatim into new files.
- `Defaults` keys live in `Kannu/models/Constants.swift`, string literal matching the property name (`static let foo = Key<Bool>("foo", ...)`). Enum-valued settings follow the `ExternalDisplayStyle` idiom: `String` raw value, `CaseIterable`, `Defaults.Serializable`, `Identifiable`, `localizedName` + `description`.
- User-facing strings use `String(localized:)`.
- A new Settings row needs a `settingsSearchIndex` entry whose `highlightID` **exactly matches** the row's `.settingsHighlight(id:)` — a mismatch silently breaks scroll-to-highlight.
- Managers are `XxxManager.swift` singletons in `Kannu/managers/` (`static let shared`, `private init`, `@MainActor` where AppKit/UI state is touched).

## Build, test, and run

- Verification build (no signing): `xcodebuild -project Kannu.xcodeproj -scheme Kannu -configuration Debug CODE_SIGNING_ALLOWED=NO build`
- Runnable dev build: prefer the stable local identity `CODE_SIGN_IDENTITY="Kannu Dev"` (a self-signed code-signing cert in the login keychain — check with `security find-identity -v -p codesigning`; create once via Keychain Access › Certificate Assistant, type Code Signing, name `Kannu Dev`). A stable identity keeps TCC grants (Accessibility etc.) valid across rebuilds. If the identity doesn't exist, fall back to ad-hoc: `CODE_SIGN_IDENTITY="-"` — but every ad-hoc rebuild mints a new code identity, so **all TCC grants die on each rebuild** and must be re-granted. Either way add `CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual` and a `-derivedDataPath`, then launch the produced `.app` with `open`. Never launch the bare executable — it aborts with a TCC violation outside a proper launch context. **Trap: `xcodebuild test … CODE_SIGNING_ALLOWED=NO` rebuilds the app product UNSIGNED in the same derivedData, silently stomping an identity-signed product.** Always re-run the signed `build` as the last step before copying to `/Applications`, and verify with `codesign -dr-` (expect `certificate leaf`, not a bare `cdhash`).
- App logs go through `os.Logger` (subsystem `com.kannu.app`); read them with **`/usr/bin/log show --predicate ...`** — spell out the path, because `log` is a zsh builtin (`whence -w log` → `log: builtin`) and a builtin always wins over `PATH`, so bare `log show …` never reaches Apple's tool. It fails with `zsh:log:1: too many arguments`, which reads like a syntax mistake in your predicate.
- Branch model: day-to-day work lands on `development`; `main` is the release branch; PRs target `development`.
- Headless test run, in a derivedData path of its own so it cannot stomp a signed product:
  `xcodebuild test -project Kannu.xcodeproj -scheme KannuTests -destination "platform=macOS" -derivedDataPath .build-tests`

## Testing

Pure unit tests for state transitions and business logic; integration tests for agent detection; UI tests only when UI behavior genuinely requires them. No tests of SwiftUI implementation details. For agent status logic, prioritize deterministic state-transition tests.

One asymmetry worth knowing before adding a test, because it is not discoverable: a **new test file
needs no `project.pbxproj` edit** — the target picks up `KannuTests/` through a synchronized group. A
**production file you want to test does** need adding to that target's explicit Sources phase, and only
Foundation-only files can go there.

## Security and privacy

Kannu runs locally. Treat process inspection, shell commands, filesystem access, agent output, terminal state, credentials, environment variables, permissions, and network access as security-sensitive. Least privilege; native APIs; no arbitrary command execution or unnecessary privileges. Never expose secrets in logs — use OSLog appropriately and never log sensitive user data.

## Commit and PR guidelines

`CONTRIBUTING.md` has the full process; PRs target `development`, one concern each. The part that
rejects commits is the CHANGELOG entry, so it is restated here in full rather than linked:

1. Define the **developer feature label** — what you are building.
2. Define the **agent feature label** if an agent did any of the work. The line is required either
   way; write `none — human-authored` when it did not.
3. Add one new entry at the **top** of `## [Unreleased]` in `CHANGELOG.md`, in exactly this shape:

   ```markdown
   ### YYYY-MM-DD - <a short title for the change>
   - **Developer label:** <the developer feature label, or the request in the requester's own words>
   - **Agent label:** <agent feature label, or "none — human-authored">
   - **Changes:**
     - <one concrete change per bullet>
   ```

   The heading and the `Developer label` are not the same string: the heading titles the change,
   while the label names the feature or quotes the request that prompted it. Every entry in
   `CHANGELOG.md` follows that split — read the last few before writing yours.
4. Stage `CHANGELOG.md` in the same commit as the code.
5. Derive the commit subject from the developer label, not from the diff.

**`.githooks/pre-commit` parses that shape literally.** The bold keys and their trailing colons are the
contract; a wrong shape is a rejected commit, not a style note.
`KannuTests/ChangelogRuleDocsTests.swift` pins this text against the hook's own parser, so if the two
ever disagree, CI says so instead of an agent finding out at commit time.

## Output expectations

For coding tasks report: what changed, why, files affected, important architectural decisions, testing performed, remaining concerns. For audits report: finding, location, why it matters, severity, recommended fix. Never claim code was tested, built, or verified unless that operation was actually performed.

## Known traps (learned the hard way — verify before assuming they changed)

- The **pre-commit hook** requires a staged `CHANGELOG.md` entry under `## [Unreleased]` with every source commit, and rejects a hook-script mirror mismatch. It does **not** build — it is bash/awk and runs in milliseconds. (A previous version of this file claimed it builds; that was wrong.)
- **Debug builds put the real code in `Kannu.app/Contents/MacOS/Kannu.debug.dylib`** — the main binary is a tiny stub, so string-grepping it for new code gives false negatives.
- A recreated build directory can leave a **stale xcodebuild build database** that reports `BUILD SUCCEEDED` with zero compile tasks. When verifying a build, confirm compile activity (or delete the derivedData path first).
- **`AppDelegate.init` constructs singletons eagerly, before `applicationDidFinishLaunching`.** A first touch of any TCC-protected resource there (Bluetooth, ~/Downloads, …) blocks the main thread until the permission dialog is answered — and ad-hoc rebuilds change the code signature, so the prompts recur after every rebuild. First touches of protected resources must happen on a background queue.
- **`Defaults.publisher(...)` without `options: []` fires an initial event on subscription** — any sequencing built on "this only fires on change" silently breaks.
- `AgentHookInstaller` embeds the hook script (authoritative, versioned via `KANNU_HOOK_SCRIPT_VERSION`); `scripts/kannu-agent-status.sh` is a generated mirror — never let them drift. This is now enforced by the pre-commit hook, because the prose version of this rule failed three times.
- **CI runs on push and PR to both `main` and `development`** (`.github/workflows/ci.yml`) — but a PR whose *base* is a feature branch gets no Build job at all, only SonarCloud, so a stacked PR can look green having never been compiled. Check which jobs actually ran before trusting a tick.
- **Recurring regressions and the invariants that prevent them: `docs/REGRESSIONS.md`.** Read it before changing anything under `Kannu/managers/AgentStatus/` **or any file in that document's Danger zones table** — the table is the list that matters, and it now reaches outside AgentStatus (`ModalPresenter.swift`, `BluetoothAudioManager.swift`). Scoping this line to one directory is exactly why an invariant that was already written down got re-broken twice in a file it did not name. When a rule in that file breaks again, add the dated addendum in the same commit as the fix.

## Instruction-file integrity

This file is canonical; `CLAUDE.md` imports it with `@AGENTS.md`, and
`KannuTests/ChangelogRuleDocsTests.swift` pins that import, the split, and the CHANGELOG shape above.
Write property wrappers and attributes in backticks — `@MainActor`, never bare — because Claude Code
parses a bare `@token` outside backticks as a file import. Do not run `/init` here: it rewrites
`CLAUDE.md` and would drop the import. If you are reading this sentence, the import resolved.
