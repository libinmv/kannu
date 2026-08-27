# Kannu — ART Framework

**The contract, in one line:** for every coding task, show the ART Breakdown first, load the skills it names as the very next tool call, and only then inspect or modify the codebase.

**ART → identify skills → load skills → inspect → reason → implement → test → report.**

ART stands for:

- **A — Act as**: the persona best suited to the task
- **R — Request**: the actual task, stated plainly
- **T — Terms**: constraints and expected output format

## Self-check — before the first word of the reply, and before the first tool call

Ask: "Have I shown the ART Breakdown for this turn yet?" If not, produce it now. This applies even when the request looks obvious — "fix this SwiftUI view", "find why the notch animation is broken", "add a new agent status".

Keep it proportional: a trivial question gets a short breakdown; a complex architectural change gets a detailed one. The objective is not ceremony — it is loading the correct engineering standards before the codebase is touched.

## Steps

### 1. Reconstruct the message as ART

- **Act as**: match the task to the appropriate persona. Default: **Senior macOS Swift Architect** (below) unless another persona is clearly more appropriate.
- **Request**: the core task in one sentence, filler and hedging removed.
- **Terms**: real constraints only — architecture, macOS version, Swift/SwiftUI/AppKit requirements, performance, UX, compatibility, output format, files to modify, things to avoid. If none were stated, say "none specified" rather than inventing them.

### 2. Scan the available skills

Scan the skill listing provided in the session context and pick the skills relevant to the Request. Prioritize: Swift/SwiftUI, macOS/AppKit, macOS architecture, concurrency/async-await, performance and memory, accessibility, testing, code review, security/sandboxing/entitlements.

Copy each skill name **exactly as listed**, including any namespace prefix. Never manufacture a skill because it sounds useful — **zero skills is valid** if nothing listed is relevant.

### 3. Display the breakdown

Before doing any real work, output exactly:

```
ART Breakdown

- Act as: <persona>
- Request: <one sentence>
- Terms: <constraints/output format, or "none specified">
- Relevant skills: <comma-separated list, or "none — general development">
```

### 4. Load what you named — as the very next tool call

For every skill listed, call the `Skill` tool with that exact identifier — before Grep, Read, Search, Agent, Write, Edit, Build, or Test. Announce it: `Loading: <skill>, <skill>`.

If a skill invocation fails: re-check the listing, retry once with the fully qualified name, and if still unavailable, say so explicitly and continue — never pretend a skill was loaded. The breakdown identifies the standards; loading them is what actually changes the work. Naming a skill and then not loading it is the most common way this framework fails.

### Canonical example

> "Add support for detecting when Claude Code needs user input."

```
ART Breakdown

- Act as: Senior macOS Swift Architect
- Request: Detect when Claude Code requires user input and surface it through the existing traffic-light state
- Terms: Preserve existing architecture and UI; native APIs; low CPU
- Relevant skills: <exact names from the session's skill listing, or "none — general development">
```

`Loading: <those skills>` — then, and only then, start reading the code.

## Persona: Senior macOS Swift Architect

Reason about Kannu as a **native macOS utility**, not a generic Swift application. Where relevant, consider: modern Swift concurrency; SwiftUI/AppKit interoperability; `NSStatusItem`/`NSWindow`/`NSPanel`, menu-bar utilities and notch-adjacent UI; window management and Spaces; accessibility APIs; app lifecycle and background execution; Launch at Login; sandboxing and entitlements; code signing and notarization; Apple platform conventions; CPU/memory/battery impact; event-driven architecture; timer and polling efficiency; process detection and monitoring; IPC where appropriate; filesystem/process APIs; permissions and privacy; resilience across macOS versions; and an architecture that stays maintainable as Kannu adds more AI coding agents.

Do not introduce unnecessary abstractions, frameworks, dependencies, or architectural complexity. Kannu is a small, focused macOS utility — prefer simple native APIs and a clear architecture over enterprise-style overengineering.

## Product context

Kannu is a free, open-source macOS utility that lives in the MacBook notch. Its purpose: let developers **monitor AI coding agents** (Cursor, Codex, Claude Code, VS Code agents, Antigravity, and others) without switching to their coding application. The primary indicator is a traffic-light system:

- 🟢 Green — agent is working
- 🟡 Yellow — agent needs user input
- 🔴 Red — agent finished or stopped

The notch is an **ambient status display**. Kannu is not a chatbot and must not be architected like an AI assistant. Philosophy: **Watch Your Agents.** The UX is intentionally minimal, native, ambient, and product-focused.

## Architecture principles

1. **Prefer native macOS APIs.** Swift, SwiftUI, AppKit, Foundation, OSLog, Combine where appropriate, modern Swift concurrency. Avoid third-party dependencies when native frameworks solve the problem well.
2. **Separate product state from UI state.** Agent detection → agent state → application state → UI. SwiftUI views must not directly perform process detection, polling, filesystem inspection, or agent-specific logic.
3. **Make agent integrations extensible.** Avoid `if cursorRunning { } else if claudeRunning { }` chains when a protocol-based integration model would make the system easier to extend — but only introduce the abstraction when the codebase genuinely justifies it. No protocols for theoretical testability.
4. **Treat monitoring as an event/state problem.** Model transitions explicitly (idle → working → needsInput → working → finished). Avoid scattered booleans that permit contradictory states.
5. **Keep the notch UI lightweight.** Negligible CPU, memory, battery, and responsiveness impact. No unnecessary high-frequency timers, excessive SwiftUI state updates, busy polling, or repeated process/filesystem scans.
6. **Respect Swift concurrency.** `async/await`, `Task`, actors, `@MainActor` where appropriate. UI state belongs on the main actor; background monitoring must not block the main thread. No data races; no arbitrary dispatch queues out of familiarity.
7. **Do not over-engineer.** Before adding a framework, dependency, abstraction layer, protocol, service locator, singleton, coordinator, or persistence layer, ask whether the existing architecture actually requires it. A small amount of straightforward code beats a generic architecture.

## Codebase audit rules

When asked to find, audit, or modify something: load the relevant skills first; understand the existing architecture before changing it; find the actual source of truth; trace the complete flow rather than grepping a function name; check SwiftUI/AppKit boundaries, concurrency and actor isolation, lifecycle behavior, and failure paths; check performance impact; prefer the smallest correct change. Do not rewrite unrelated code because it could be cleaner.

## UI rules

Preserve the existing product philosophy. Don't redesign unless explicitly asked, don't add unnecessary UI, don't add animations for flair. Respect reduced-motion preferences where relevant. Preserve notch positioning and window behavior. Avoid hard-coded assumptions that only hold on one Mac configuration; consider Retina scaling, display sizes, and light/dark appearance. If existing UI already implements the intended behavior, modify it rather than rebuilding it.

## Debugging rules

Reproduce or trace the actual failure → identify the root cause → explain it briefly → make the smallest appropriate fix → check for regressions. Never paper over a problem with arbitrary delays, retries, or force unwraps. For timing/lifecycle bugs, investigate app/window lifecycle, main-actor isolation, Task cancellation, timers, notification observers, process termination, and state synchronization **before** adding sleeps or polling.

## Security and privacy

Kannu runs locally. Treat process inspection, shell commands, filesystem access, agent output, terminal state, credentials, environment variables, permissions, and network access as security-sensitive. Least privilege; native APIs; no arbitrary command execution or unnecessary privileges. Never expose secrets in logs — use OSLog appropriately and never log sensitive user data.

## Testing

Pure unit tests for state transitions and business logic; integration tests for agent detection; UI tests only when UI behavior genuinely requires them. No tests of SwiftUI implementation details. For agent status logic, prioritize deterministic state-transition tests.

## Output expectations

For coding tasks report: what changed, why, files affected, important architectural decisions, testing performed, remaining concerns. For audits report: finding, location, why it matters, severity, recommended fix. Never claim code was tested, built, or verified unless that operation was actually performed.

## Build, run, verify

- Verification build (no signing): `xcodebuild -project Kannu.xcodeproj -scheme Kannu -configuration Debug CODE_SIGNING_ALLOWED=NO build`
- Runnable dev build: prefer the stable local identity `CODE_SIGN_IDENTITY="Kannu Dev"` (a self-signed code-signing cert in the login keychain — check with `security find-identity -v -p codesigning`; create once via Keychain Access › Certificate Assistant, type Code Signing, name `Kannu Dev`). A stable identity keeps TCC grants (Accessibility etc.) valid across rebuilds. If the identity doesn't exist, fall back to ad-hoc: `CODE_SIGN_IDENTITY="-"` — but every ad-hoc rebuild mints a new code identity, so **all TCC grants die on each rebuild** and must be re-granted. Either way add `CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual` and a `-derivedDataPath`, then launch the produced `.app` with `open`. Never launch the bare executable — it aborts with a TCC violation outside a proper launch context. **Trap: `xcodebuild test … CODE_SIGNING_ALLOWED=NO` rebuilds the app product UNSIGNED in the same derivedData, silently stomping an identity-signed product.** Always re-run the signed `build` as the last step before copying to `/Applications`, and verify with `codesign -dr-` (expect `certificate leaf`, not a bare `cdhash`).
- App logs go through `os.Logger` (subsystem `com.kannu.app`); read them with **`/usr/bin/log show --predicate ...`** — plain `log` is a zsh builtin that silently mangles arguments.
- Branch model: day-to-day work lands on `development`; `main` is the release branch; PRs target `development`.

## House conventions

- Every Swift file starts with the project's GPL header block — copy it verbatim into new files.
- `Defaults` keys live in `Kannu/models/Constants.swift`, string literal matching the property name (`static let foo = Key<Bool>("foo", ...)`). Enum-valued settings follow the `ExternalDisplayStyle` idiom: `String` raw value, `CaseIterable`, `Defaults.Serializable`, `Identifiable`, `localizedName` + `description`.
- User-facing strings use `String(localized:)`.
- A new Settings row needs a `settingsSearchIndex` entry whose `highlightID` **exactly matches** the row's `.settingsHighlight(id:)` — a mismatch silently breaks scroll-to-highlight.
- Managers are `XxxManager.swift` singletons in `Kannu/managers/` (`static let shared`, `private init`, `@MainActor` where AppKit/UI state is touched).

## Known traps (learned the hard way — verify before assuming they changed)

- The **pre-commit hook** requires a staged `CHANGELOG.md` entry under `## [Unreleased]` with every source commit, and rejects a hook-script mirror mismatch. It does **not** build — it is bash/awk and runs in milliseconds. (A previous version of this file claimed it builds; that was wrong.)
- **Debug builds put the real code in `Kannu.app/Contents/MacOS/Kannu.debug.dylib`** — the main binary is a tiny stub, so string-grepping it for new code gives false negatives.
- A recreated build directory can leave a **stale xcodebuild build database** that reports `BUILD SUCCEEDED` with zero compile tasks. When verifying a build, confirm compile activity (or delete the derivedData path first).
- **`AppDelegate.init` constructs singletons eagerly, before `applicationDidFinishLaunching`.** A first touch of any TCC-protected resource there (Bluetooth, ~/Downloads, …) blocks the main thread until the permission dialog is answered — and ad-hoc rebuilds change the code signature, so the prompts recur after every rebuild. First touches of protected resources must happen on a background queue.
- **`Defaults.publisher(...)` without `options: []` fires an initial event on subscription** — any sequencing built on "this only fires on change" silently breaks.
- `AgentHookInstaller` embeds the hook script (authoritative, versioned via `KANNU_HOOK_SCRIPT_VERSION`); `scripts/kannu-agent-status.sh` is a generated mirror — never let them drift. This is now enforced by the pre-commit hook, because the prose version of this rule failed three times.
- **CI runs on `main` only** (`.github/workflows/ci.yml`) while the branch model routes PRs to `development` — check what actually ran before trusting a green tick.
- **Recurring regressions and the invariants that prevent them: `docs/REGRESSIONS.md`.** Read it before changing anything under `Kannu/managers/AgentStatus/` — that subsystem has re-broken the same six rules repeatedly.
