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

- **Act as**: match the task to the appropriate persona. Default: the **Senior macOS Swift Architect** persona defined in `AGENTS.md`, unless another persona is clearly more appropriate.
- **Request**: the core task in one sentence, filler and hedging removed.
- **Terms**: real constraints only — architecture, macOS version, Swift/SwiftUI/AppKit requirements, performance, UX, compatibility, output format, files to modify, things to avoid. If none were stated, say "none specified" rather than inventing them.

### 2. Scan the available skills

Scan the skill listing provided in the session context and pick the skills relevant to the Request. Prioritize: Swift/SwiftUI, macOS/AppKit, macOS architecture, concurrency/async-await, performance and memory, accessibility, testing, code review, security/sandboxing/entitlements.

Copy each skill name **exactly as listed**, including any namespace prefix. Never manufacture a skill because it sounds useful — **zero skills is valid** if nothing listed is relevant.

**Mandatory skill — `caveman`:** this project always loads the `caveman` skill (installed at `.claude/skills/caveman/`). Include it in **every** ART breakdown's "Relevant skills" line and load it with the other named skills — even when no other skill applies. It sets the response style (terse, full technical substance, code/errors exact); it never replaces the task-relevant skills, it accompanies them.

### 3. Display the breakdown

Before doing any real work, output exactly:

```
ART Breakdown

- Act as: <persona>
- Request: <one sentence>
- Terms: <constraints/output format, or "none specified">
- Relevant skills: caveman, <comma-separated list, or just "caveman" when nothing else applies>
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
- Relevant skills: caveman, <exact names from the session's skill listing, or just "caveman">
```

`Loading: <those skills>` — then, and only then, start reading the code.

## Everything else lives in AGENTS.md

Kannu's engineering standards — the product context, the Senior macOS Swift Architect persona, the
architecture principles, the build/test/run commands, the house conventions, the commit checklist and
the known traps — are in `AGENTS.md`, the canonical vendor-neutral instruction file every agent working
in this repo reads. It is imported below, so it is already in your context: do not spend a file read on
it.

Only Claude-Code-specific machinery belongs in this file. Anything true regardless of which agent is
running goes in `AGENTS.md`. `KannuTests/ChangelogRuleDocsTests.swift` pins that split, and pins this
import as the last line — keeping it last is what leaves the ART contract above first, where "before
the first tool call" needs it to be.

@AGENTS.md
