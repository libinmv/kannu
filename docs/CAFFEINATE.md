# Caffeinate

Keeps the Mac awake for agent work. One native IOPM power assertion, driven by two toggles.
No `caffeinate` subprocess is ever spawned.

## The pipeline

`CaffeinateManager.reconcile()` runs the same three stages on every event
(toggle change, feature change, session change, launch):

1. **Decision** — `AgentTrafficLightMapper.shouldKeepAwake(smartEnabled:manualEnabled:featureEnabled:hasActiveVisibleSession:)`
2. **Transition** — `AgentTrafficLightMapper.caffeinateTransition(isHeld:heldModeIsSmart:shouldHold:smartNow:)`
3. **Command** — `CaffeinateManager.apply(_:smart:)`: one `switch`, each arm one or two IOPM calls.

Stages 1 and 2 are pure functions in `AgentTrafficLightState.swift` and are pinned row-for-row
by `KannuTests/CaffeinateDecisionTests.swift`. **A change to either table must update the code,
these docs, and the tests in the same commit.**

## Decision table

| feature enabled | smart | manual | active session | hold? |
|---|---|---|---|---|
| no | – | – | – | **no** (all controls are hidden with the feature off; holding would strand the user) |
| yes | on | – | yes | **yes** |
| yes | on | – | no | **no** (manual is ignored while smart is on) |
| yes | off | on | – | **yes** |
| yes | off | off | – | **no** |

"Active session" = visible, not a simulation, and in an active run (thinking / executing /
awaiting input) — `hasCaffeinateWorthySession`, the same definition the traffic light uses.

## Transition table

| held? | mode matches? | should hold? | action |
|---|---|---|---|
| no | – | yes | `create` |
| yes | – | no | `release` |
| yes | yes | yes | `none` |
| yes | no | yes | `refresh` (release + create, so the reason string reports the real mode) |
| no | – | no | `none` |

A failed create logs, marks not-held, and arms **one** 5-second retry that re-runs a full
reconcile. Any real event cancels the pending retry first.

## Debugging

```sh
log stream --predicate 'subsystem == "com.kannu.app" AND category == "Caffeinate"'
pmset -g assertions | grep -i kannu
```

Expect a `PreventUserIdleSystemSleep` assertion owned by process `Kannu`, named either
`Kannu — keeping the Mac awake` (manual) or `Kannu — keeping the Mac awake while AI agents run`
(smart). The dash is an em dash (U+2014): a plain-hyphen grep on the name will miss it.
`pgrep caffeinate` finding nothing is correct — there is no subprocess.

Log lines: `init: …`, `reconcile(<trigger>): … → <transition>`, `☕ holding …`, `💤 released …`,
`failed to create sleep assertion (…); retrying in 5s`. Triggers: `init`, `manual toggle`,
`smart toggle`, `feature toggle`, `sessions`, `retry`.

## What it deliberately does NOT do

- **Display sleep is untouched** and **closing the lid always sleeps the Mac** — the assertion
  type is `PreventUserIdleSystemSleep`, the same scope as `caffeinate -i`.
- **No quit/crash cleanup code exists on purpose**: powerd reclaims a process's assertions on
  any exit, including SIGKILL. Adding a handler would only duplicate the kernel's guarantee.
- The manual toggle stays stored (and re-arms) while smart mode hides it — smart wins outright,
  documented in the manager header.
- Release latency after an agent stops is bounded by the session monitor's rescan (worst case
  the 30-second safety-net poll). `awaitingInput` counts as active for up to its 5-minute
  staleness window.
