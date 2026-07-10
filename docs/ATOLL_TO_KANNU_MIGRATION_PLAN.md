# Atoll to Kannu Compatibility Migration Plan

This document defines a non-breaking path to migrate extension protocol naming
from `atoll.*` to `kannu.*` while preserving existing extension clients.

## Scope Boundaries

- Keep legacy compatibility for:
  - `AtollExtensionKit` package and imported type names
  - `atoll.*` JSON-RPC method/notification names
  - Existing persisted legacy identifiers (`atoll:id=`, `.atoll` paths)
- Avoid direct breaking renames in one release.

## Phase 1 - Dual namespace support (server-side)

1. Add method aliasing in `ExtensionRPCService`:
   - Accept both `atoll.*` and `kannu.*` method names.
   - Route both namespaces to the same handlers.
2. Add notification dual-emit in `ExtensionRPCServer`:
   - Emit current `atoll.*` notifications and mirrored `kannu.*` notifications.
3. Add targeted tests:
   - Method dispatch tests for both namespaces.
   - Notification payload parity tests.

**Status:** Implemented in `ExtensionRPCNamespace.swift`, `ExtensionRPCService.swift`, and `ExtensionRPCServer.swift`.

Example client migration:

```json
{ "jsonrpc": "2.0", "method": "kannu.getVersion", "id": "1" }
```

Legacy clients may continue using:

```json
{ "jsonrpc": "2.0", "method": "atoll.getVersion", "id": "1" }
```

Both resolve to the same handler. Server notifications are emitted on both namespaces during the transition window.

## Phase 2 - Client SDK transition

1. Introduce a Kannu-facing client API:
   - New constants/helpers for `kannu.*`.
2. Preserve old API with deprecation:
   - Keep `atoll.*` constants as deprecated aliases.
3. Publish migration notes:
   - Side-by-side old/new examples for extension developers.

## Phase 3 - Adoption monitoring

1. Add lightweight telemetry/log counters for namespace usage:
   - Count calls received via `atoll.*` vs `kannu.*`.
2. Define retirement threshold:
   - For example, no `atoll.*` usage across N releases.
3. Keep migration paths for persisted user data regardless of RPC retirement.

## Phase 4 - Decommission (when ready)

1. Remove `atoll.*` RPC aliases after threshold is met.
2. Keep legacy data migration (`atoll:id=`, `.atoll`) for upgrade safety.
3. Keep clear rollback path:
   - Re-enable alias map quickly if extension breakage is reported.

## Rollout Checklist

- [x] Dual namespace dispatch merged and tested.
- [ ] Extension docs updated with deprecation timeline.
- [ ] Runtime observability confirms namespace adoption.
- [ ] Decommission criteria approved.

## Rollback Strategy

- Preserve alias map code path behind a feature flag or isolated dispatcher.
- If regressions appear, re-enable `atoll.*` aliases and redeploy.
- Postmortem broken client patterns and extend compatibility window.

