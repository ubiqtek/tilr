# Delta 13-2: Apply Default Config Command

**Status: DESIGN**

Implement the **ApplyDefaultConfig** orchestrator command and the pipeline execution harness that supports it. This delta focuses on:

1. **Config application logic:** Translate user config (spaces, app assignments) into a sequence of primitive commands
2. **Pipeline harness:** Build the sequential execution framework (`CommandPlanner`, `PlanExecutor`, `StateCoordinator.record`) that allows commands to flow through Plan → Execute → Record
3. **Snapshot creation:** Implement immutable snapshots that record command intent, outcomes, and state transitions

## Context

The pipeline model (from `doc/arch/tilr-arch-v2.md`) defines a strict one-command-per-snapshot architecture. `ApplyDefaultConfig` is the first use case that exercises the full pipeline:

```
User config loaded at startup
  │
  ├─ ApplyDefaultConfig orchestrator (NOT a command; a coordinator)
  │   │
  │   └─ Submits primitive commands sequentially to the pipeline:
  │      1. CreateSpace("Coding")           → Snapshot 1
  │      2. CreateSpace("Reference")        → Snapshot 2
  │      3. AssignAppToSpace(xcode, Coding) → Snapshot 3
  │      4. AssignAppToSpace(zen, Coding)   → Snapshot 4
  │      ... more commands ...
  │
  └─ End: TilrState reflects configured spaces, apps are assigned, audit log has 4+ snapshots
```

## Goals

1. **ApplyDefaultConfig implementation**
   - Parse user config (spaces, layout preferences, app-to-space mappings)
   - Decompose into primitive commands (`CreateSpace`, `AssignAppToSpace`)
   - Coordinate their execution through the pipeline in dependency order

2. **Pipeline harness**
   - Implement `CommandPlanner` protocol and plan generators for primitives
   - Implement `PlanExecutor` protocol with StateOnlyExecutor (no AX calls for startup)
   - Build `StateCoordinator` with `record(plan:, outcomes:)` method
   - Implement sequential input queue that prevents overlapping command execution

3. **Snapshot data model**
   - Define `Snapshot` struct: `(command, plan, outcomes, stateAfter)`
   - Implement history log (`[Snapshot]`) for auditability and replay

4. **Testing**
   - Unit tests for plan generation (command intent → actions)
   - Integration tests for config parsing → snapshot sequence
   - Replay tests: feed snapshots back through state updates, verify final state

## Scope

- **In scope:**
  - User config parsing (spaces, app assignments)
  - ApplyDefaultConfig orchestrator
  - Primitive command types (CreateSpace, AssignAppToSpace, etc.)
  - CommandPlanner and plan generation
  - StateOnlyExecutor (state-only operations, no AX)
  - StateCoordinator.record()
  - Snapshot data model and history log

- **Out of scope (Delta 13-3):**
  - AXExecutor (window management, hide/show operations)
  - Hotkey routing through the pipeline
  - CLI routing through the pipeline
  - Space enumeration from Mission Control

## Dependencies

- **Requires:** Delta 13-1 (state initialization completed; TilrState model finalized)
- **Enables:** Delta 13-3 (AXExecutor can now use the same pipeline harness)

## Key Design Decisions

1. **Orchestrators are not commands:** ApplyDefaultConfig is a coordination function that submits primitives to the pipeline in sequence, not a command itself.
2. **One snapshot per command:** Each primitive command produces exactly one snapshot, keeping the audit trail granular and replayable.
3. **StateOnlyExecutor for startup:** No AX calls during config application; state changes are predictions validated against future OS events.
4. **Immutable snapshots:** Snapshots are frozen records; state is reconstructed from the snapshot sequence.

## Implementation Strategy: Incremental Startup Rewiring

The goal is to migrate the startup path to the pipeline model **without breaking existing hotkey/event handlers**. This is achieved in three incremental steps:

### Current startup flow (to be unwired)

- `AppDelegate.applicationDidFinishLaunching()` calls `svc.applyConfig(reason: .startup)` at line 70
- `applyConfig()` reads `config.displays["1"].defaultSpace` and calls `switchToSpace()`
- `switchToSpace()` fires `onSpaceActivated` event
- AppWindowManager, UserNotifier, MenuBarController listen to that event and react

### Step 1: Unwire startup logic

- Comment out `svc.applyConfig(reason: .startup)` in AppDelegate line 70
- App launches with empty state (displays only, no spaces, no apps)
- Existing AppWindowManager, UserNotifier, MenuBarController subscribers remain wired

### Step 2: Rewire with commands + pipeline (state only)

- Create `Pipeline` actor with serial execution (Plan → Execute → Record → Snapshot)
- Wire `StateOnlyExecutor` as the executor for 13-2 (no AX work yet)
- Create `ConfigApplier` orchestrator that:
  1. Parses config and generates deterministic sequence of primitive commands
  2. For each space: `pipeline.run(.createSpace(name, displayId, layout))`
  3. For each app assignment: `pipeline.run(.assignAppToSpace(bundleId, spaceName))`
  4. Final: `pipeline.run(.setActiveSpace(defaultSpaceName, displayId))`
- Each command produces one snapshot; execution is serial
- ConfigApplier returns when done — no events fired, no handlers called, no AX work
- At end of Step 2: state is fully configured, snapshots are recorded, but screen hasn't changed

### Step 3: Bridge state to screen (one-shot, scaffolding)

- After ConfigApplier finishes, emit a synthetic `service.onSpaceActivated` event with the default space name
- Do NOT call `svc.switchToSpace()` (that would mutate legacy state outside the pipeline)
- Existing subscribers react: AppWindowManager does window show/hide, UserNotifier shows popup, MenuBarController updates status bar
- Mark with `// TODO(delta-13-3): remove when AXExecutor owns window side effects` — this bridge is temporary scaffolding
- Hotkeys remain wired to legacy `svc.switchToSpace()` (unchanged for 13-2)

### Key insight

13-2 owns startup state initialization via pipeline. Window manipulation (AX work) is left to existing handlers via a bridge event. This splits the responsibility cleanly: state logic (pipeline) vs side effects (handlers). In 13-3, AXExecutor will own the side effects and the bridge will be removed.

### Future: Incremental command migration

- Hotkeys will eventually call `await pipeline.run(.switchSpace(...))` instead of `svc.switchToSpace()`
- Events will eventually be converted to commands and piped through the pipeline
- But for now, new startup logic works via commands; existing hotkeys/events still use old call sites

## Acceptance Criteria

- [ ] `tilr state view` shows full space/app structure from config
- [ ] `tilr state history` shows all primitive commands in order
- [ ] Visual behavior identical to pre-13-2 startup (windows positioned, popup shown, menu bar updated)
- [ ] Hotkeys work unchanged (legacy path untouched)
- [ ] No legacy state mutations occur during startup; pipeline snapshots are the source of truth
- [ ] Bridge is clearly marked as temporary scaffolding for removal in 13-3

## References

- `doc/arch/tilr-arch-v2.md` — Command Execution & Pipeline Model section
- `doc/kb/specifications.md` — User config format
- Delta 13-1 (state initialization)
