# Delta 12 — State file

**Goal:** persist runtime state to `~/Library/Application Support/tilr/state.toml`
so that user actions (active space, sidebar ratios, runtime app moves) survive
a Tilr restart.

**Status:** planned

**Depends on:** Delta 11 (multi-display) — state schema must be per-display
from the start to avoid a second migration.

## Scope

State is split into two files (see `doc/arch/state-and-config.md`):

- `~/.config/tilr/config.toml` — user-owned, never written by Tilr
- `~/Library/Application Support/tilr/state.toml` — app-owned runtime state

This delta wires up the second file. The store loads on launch, saves on
mutation, and survives both clean exit and crash (atomic write via temp file +
rename).

### Persisted fields

- **`activeSpace` per display** — `[state.displaySpaces]` keyed by
  display identifier (introduced in Delta 11). Restored on launch.
- **`liveSpaceMembership`** — `[state.liveSpaceMembership]` keyed by space
  name → list of bundle IDs. Captures runtime moves (e.g. Zen moved into
  Coding via `tilr move-current`) so the move survives restart.
- **`sidebarRatios`** — `[state.sidebarRatios]` keyed by `(display, space)` →
  ratio (Float). Already partly implemented; formalise here.
- **`fillScreenLastApp`** — `[state.fillScreenApps]` keyed by space name →
  bundle ID. Restores last-focused app per fill-screen space.

### Load / save semantics

- **Load:** on `AppWindowManager.init()`, read state.toml *after* config is
  loaded; union live membership (config-pinned ∪ persisted) so newly
  config-pinned apps still appear without manual save.
- **Save:** on every mutation that changes a persisted field, debounce-write
  (250ms) to disk. Atomic via temp file + rename.
- **Schema versioning:** add `schema_version = 1` at top of state.toml. On
  load, if version mismatches, log a warning and discard incompatible
  sections rather than crash.

## Implementation steps

- [ ] Define `StateFile` struct mirroring the TOML schema; use `TOMLKit` (or
      whatever the config side uses) for codec.
- [ ] `StateStore`: add load/save plumbing; expose Combine publishers per
      field.
- [ ] Wire `AppWindowManager.liveSpaceMembership` mutations →
      `stateStore.updateLiveMembership(...)` → debounced save.
- [ ] Wire `SidebarResizeObserver` ratio updates → state save.
- [ ] On launch, seed `liveSpaceMembership` from union of config + persisted.
- [ ] Atomic write helper: write to `state.toml.tmp`, fsync, rename.
- [ ] Migration: if existing `state.toml` has single-string `activeSpace`
      (pre-Delta 11), promote it under `NSScreen.main`'s display key.

## Verification

- [ ] Move Zen into Coding → quit Tilr → relaunch → Zen still listed in
      Coding's live membership.
- [ ] Drag sidebar ratio → quit → relaunch → ratio restored.
- [ ] Switch to space A on display 1, B on display 2 → quit → relaunch →
      both displays restore to their respective spaces.
- [ ] Corrupt state.toml manually → relaunch → Tilr logs warning and starts
      with defaults (no crash).

## Open questions

1. Save cadence: 250ms debounce ok, or save on every mutation? (Concern:
   slot-activated reflows could fire many writes per second.)
2. Should config-pinned apps be persisted in `liveSpaceMembership`, or only
   computed on-the-fly as the union? (Storing them is redundant but
   simplifies load logic.)
