# Delta 13-1: App Startup & State Initialization + Observability

## Design decisions for Delta 13-1

- **App enumeration**: Track all running apps via `NSRunningApplication`. Filter criteria can be refined in later deltas if needed.
- **Active state tracking**: Parent container tracks active child state (fractal pattern). Displays track which space is active; spaces track which apps are visible. Each object is responsible for its own active-child tracking.
- **Display identity**: Use existing `DisplayStateStore` UUID→ID mapping (hardware-level CGDisplay UUIDs persisted in `~/.local/share/tilr/display-state.json`, with numeric IDs in config). StateInitializer calls `DisplayStateStore.resolveId()` for each connected display.
- **CLI state access**: Client/server arrangement only. `tilr state view` queries the running app via socket; if app not running, fail gracefully. All-in-memory state (no persistence yet; that's Delta 15-2).
- **State storage**: `StateCoordinator` actor holds mutable state and immutable history. No singletons. Injected explicitly into collaborators (SocketServer, CommandHandler, pipeline phases). `TilrStateSnapshot` (Sendable value type) used for read paths and cross-process communication.
- **State mutations**: Via `StateCoordinator.record(plan:, outcomes:)` — creates new snapshot from execution outcomes, appends to immutable history. Record phase bridges Execute phase outcomes to state evolution. Audit trail of all state changes with timestamps and reasons.

**Goal:** Get the app to start up, initialize TilrState from config, and expose it via a CLI command for inspection.

## What we're building

1. **TilrState initialization** (app startup) — read displays, load space config, initialize state
2. **State persistence** — store state to disk after each successful execution (allows recovery on crash)
3. **CLI observability** — `tilr state view` displays state as a tree (displays → spaces → apps)
4. **JSON export** — `tilr state export` for scripting / testing

## State storage architecture (StateCoordinator actor)

State is owned by a `StateCoordinator` actor, held by AppDelegate as the single root reference. Explicit injection into collaborators (no singletons).

- **Thread-safe by design** — `actor` type prevents data races on concurrent access (socket reads, future pipeline mutations)
- **Immutable history** — Each state change recorded as `TilrStateSnapshot` (Sendable value type) appended to history. Audit trail with timestamps and reasons.
- **Record phase** — `StateCoordinator.record(plan:, outcomes:)` evolves state from execution outcomes (not predictions), creates snapshot, appends to history.
- **Future-proof for mutations** — Pipeline phases call `await coordinator.record(...)` atomically; undo/redo becomes possible from history.

## Architecture pieces involved

- `StateCoordinator` — actor owning mutable state and immutable history; held by AppDelegate
- `TilrState` struct (already defined in arch doc) representing displays, spaces, and apps
- `TilrStateSnapshot` — Sendable value type for read-only consumers (CLI, socket responses, formatters)
- `StateInitializer` — loads config + enumerates displays via NSScreen + running apps, builds initial state
- `StateFormatter` — renders state as human-readable tree for the CLI
- New CLI subcommand: `tilr state` with `view` and `export` actions

## Implementation sequence

1. **Define Swift types for TilrState and snapshots** (`Sources/Shared/TilrState.swift`):
   - `struct TilrState` — mutable current state (displays, spaces, apps, active children)
   - `struct Display`, `struct Space`, `struct App` — domain model
   - `enum AppDisplayState { case visible, case hidden }`
   - `struct TilrStateSnapshot: Sendable` — immutable value snapshot (includes id, timestamp, reason, previous state, plan, outcomes)
   - `struct ActionOutcome` — execution result (success/failed/timeout) with error details

2. **Create StateInitializer** (`Sources/Shared/StateInitializer.swift`):
   - `func initializeState() -> TilrState`
   - Enumerate displays via NSScreen (using existing DisplayResolver)
   - Resolve display IDs using `DisplayStateStore.resolveId()` — Tilr already maintains stable UUID→ID mappings persisted in `~/.local/share/tilr/display-state.json` from hardware CGDisplay UUIDs (vendor/model/serial). New displays auto-assign the next available numeric ID.
   - Load space definitions from config
   - Track all running apps (enumerate via NSRunningApplication)
   - Return initial TilrState

3. **Create StatePersistence** (`Sources/Shared/StatePersistence.swift`):
   - `func saveState(_ state: TilrState)` — writes to `~/Library/Application Support/tilr/state.toml`
   - `func loadState() -> TilrState?` — reads from disk; returns nil if not found
   - Use TOML (existing dependency) for serialization

4. **Create StateFormatter** (`Sources/Shared/StateFormatter.swift`):
   - `func formatAsTree(_ state: TilrState) -> String` — renders state as ASCII tree
   - Example output:
     ```
     TilrState
     ├─ Display "Built-in" (id: display-1) [active space: Coding]
     │  ├─ Space "Coding" [ACTIVE]
     │  │  ├─ App "com.apple.dt.Xcode" (VISIBLE)
     │  │  └─ App "com.microsoft.VSCode" (VISIBLE)
     │  └─ Space "Reference"
     │     └─ App "com.zen-browser.zen" (HIDDEN)
     └─ Display "LG UltraFine" (id: display-2) [active space: Scratch]
        ├─ Space "Scratch" [ACTIVE]
        │  └─ App "com.agilebits.onepassword7" (VISIBLE)
        └─ Space "Schedule"
           └─ App "com.google.Calendar" (HIDDEN)
     ```
   - `func formatAsJSON(_ state: TilrState) -> String` — JSON serialization for export

5. **Create StateCoordinator actor** (`Sources/Shared/StateCoordinator.swift`):
   - `actor StateCoordinator`
   - `private var history: [TilrStateSnapshot]`
   - `func snapshot() -> TilrStateSnapshot` — current state as Sendable snapshot
   - `func history(limit: Int) -> [TilrStateSnapshot]` — recent snapshots for audit trail
   - `func record(plan:, outcomes:)` — Record phase: evolve state from outcomes, create snapshot, append to history

6. **Wire app startup** (`Sources/Tilr/AppDelegate.swift`):
   - Create `StateCoordinator` instance in `applicationDidFinishLaunching`
   - Call `StateInitializer.initializeState()` to build initial state
   - Create first snapshot and pass to coordinator
   - Store coordinator as property on AppDelegate (the single root reference)
   - Inject coordinator into SocketServer, CommandHandler
   - Log the initialized state

7. **Add CLI `state` subcommand** (`Sources/TilrCLI/TilrCLI.swift`):
   - New subcommand `state` with actions: `view`, `export`
   - `tilr state view` — queries running app via socket for current snapshot, formats as tree, prints to stdout
   - `tilr state export` — same but outputs JSON
   - Both communicate with the running app via socket protocol (coordinator responds with `await snapshot()`)
   - Fail gracefully if app is not running

8. **Update Protocol** (`Sources/Shared/Protocol.swift`):
   - Add `TilrStateRequest` / `TilrStateResponse` to the IPC protocol
   - Response contains `TilrStateSnapshot` (the Sendable value type)
   - SocketServer deserializes request, awaits `coordinator.snapshot()`, serializes response

## Files to create

| Path | Purpose |
|---|---|
| `Sources/Shared/TilrState.swift` | Core domain types: TilrState, Display, Space, App, AppDisplayState, TilrStateSnapshot (Sendable), ActionOutcome |
| `Sources/Shared/StateInitializer.swift` | Reads config and enumerates displays/apps to build initial state |
| `Sources/Shared/StateCoordinator.swift` | Actor owning mutable state and immutable history; exposes `snapshot()` and `record(plan:, outcomes:)` |
| `Sources/Shared/StateFormatter.swift` | Renders state as ASCII tree or JSON |

## Files to modify

| Path | Change |
|---|---|
| `Sources/Shared/Protocol.swift` | Add `TilrStateRequest` and `TilrStateResponse` messages (response contains `TilrStateSnapshot`) |
| `Sources/Tilr/AppDelegate.swift` | Create `StateCoordinator` on startup. Call `StateInitializer.initializeState()`, create first snapshot, store coordinator as property. Inject into SocketServer and CommandHandler. |
| `Sources/Tilr/SocketServer.swift` | Accept coordinator reference. On `TilrStateRequest`, await `coordinator.snapshot()` and respond with snapshot. |
| `Sources/TilrCLI/TilrCLI.swift` | Add `state` subcommand with `view` and `export` actions. Query running app via socket for snapshot. |

## Acceptance criteria

- **App startup initializes state** from config + displays without crashing, creates `StateCoordinator`, creates initial snapshot
- **`tilr state view`** queries running app via socket, receives snapshot, displays as tree (at least 3 levels: Display → Space → App with visibility and active-child tracking)
- **`tilr state export`** outputs valid JSON of snapshot that can be parsed
- **State includes at least**: Display names/IDs, Space names, running App bundle IDs, visibility states, active child tracking (which space is active per display, which apps are visible per space)
- **Snapshot includes metadata**: id (UUID), timestamp, reason (why state changed), plan (what was attempted), outcomes (what happened)
- **Logging shows state initialization** on app startup (`[state] Initialized TilrState with 2 displays, 5 spaces, 12 running apps`)
- **No state diffing in the code** — only initialization and snapshot formatting. Pipeline phases (Plan, Execute, Record) come in later deltas.
- **CLI fails gracefully** if app is not running (clear error message, not a crash)

## Notes / non-goals

- Not yet executing commands or updating state (that's the next delta: `Input → Plan`)
- Not persisting state to disk yet (that comes after we have a working pipeline)
- Not handling space switching or app hide/show (that requires the full pipeline)
- CLI state commands read from the running app; they don't mutate state

---

## Appendix: Design Decision — Parent Tracking vs Child State

### Decision: Parents track active/visible child state

`Display` owns `activeSpaceId: String?` (which space is active on this display).
`Space` owns `visibleAppIds: Set<String>` (which apps are visible in this space).
Children (`Space`, `App`) do not track their own active/visible status; they expose computed helpers for convenience.

### Rationale

**Data integrity:** With parent tracking, "exactly one active space per display" is encoded in the type system. Child-tracked state (`space.isActive: Bool` on each space) permits invalid states: zero, two, or N active spaces have no compile-time or runtime guard. Validation becomes an unbounded scan of all children.

**Atomicity:** Switching active space is one atomic write (`activeSpaceId = newId`). With child tracking, flipping two children's `isActive` flags between those writes leaves state inconsistent. Swift value types lessen the race-condition risk, but the *modeling* still permits transient invalidity.

**Record phase mutations:** When the pipeline's Execute phase returns outcomes, the Record phase updates state. Example: "Plan said activate space X; Execute returned failure — space Y is still active." 

With parent tracking: `display.activeSpaceId = outcome.actualActiveSpaceId` (one assignment).

With child tracking: loop all spaces, set each's `isActive` flag. On partial failures (e.g., 3 of 4 apps hid successfully), spreading one semantic fact across N children risks a missed update.

**Fractal structure:** This approach correctly repeats the pattern: at every level, the *parent* owns "which children are foregrounded." That's the relational structure of the fractal pattern. Child-tracked flags repeat a primitive, losing the hierarchy.

**Serialization:** Parent-tracked IPC is more compact and unambiguous (`"activeSpaceId": "uuid-123"` vs N boolean flags). Malformed snapshots can't represent invalid states (e.g., two active spaces on the wire).

### Ergonomics

Callers needing to ask "is this app visible?" can use computed helpers:
```swift
extension Space {
    func isVisible(_ app: App) -> Bool { visibleAppIds.contains(app.id) }
}
extension Display {
    var activeSpace: Space? { spaces.first { $0.id == activeSpaceId } }
}
```

The canonical store is parent-owned; derived views are read-only projections for convenience.
