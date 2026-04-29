# Delta 11 — Multi-display support

**Goal:** make spaces and layouts per-display, so users with multiple monitors
can have an independent active space (and layout) on each screen.

**Status:** next

## Background

Tilr currently hardcodes `NSScreen.main` everywhere — every layout, every
space switch, every frame computation assumes a single display. The config
already has a `displays` section with per-display default spaces, but the
runtime ignores it.

**Reference docs (read before starting):**
- `doc/arch/macos-windowing.md` — `NSScreen` properties (`frame`,
  `visibleFrame`, `uuid`)
- `doc/arch/space-switching.md` §"Multi-display (future)"
- `doc/arch/state-and-config.md` §"Per-display active space"
- `doc/arch/cross-space-switching.md` §"Multi-display (Delta 10+)"
- `doc/arch/move-window-to-space-flow.md` — current single-display assumptions
- Hammerspoon `init.lua` — search for `screen` / `screens()` for the reference
  per-display behaviour

## Scope

- **Per-display active space:** replace single `activeSpace` with a map keyed
  by display identifier (UUID or persistent ID). `SpaceService` and
  `StateStore` must read/write per-display.
- **Display-scoped space lookup:** when activating a space, find the display
  that owns it (via config `displays` map) and apply layout to that display's
  `NSScreen`, not `NSScreen.main`.
- **Per-display hotkeys:** hotkey activation routes to whichever display
  currently owns that space in runtime state. User can reassign a space to a
  different display at runtime via `CMD+SHIFT+1-n` (n = display integer ID).
- **Per-display layout:** `LayoutStrategy.apply` already takes a `screen:
  NSScreen` parameter; audit all callers to ensure the correct screen is
  passed (not `NSScreen.main`).
- **Cross-space follow-focus on target display:** when CMD+TAB activates an
  app whose space lives on a different display, switch that display's active
  space — don't drag the app to the current display.
- **Move-to-space across displays:** `tilr move-current` must respect the
  target space's owning display. Window move + reframe happens on that
  display's frame.
- **Display hotplug:** handle `NSApplication.didChangeScreenParametersNotification`
  — re-resolve display→space mapping when monitors are connected/disconnected.
- **`tilr displays list`** — show all known displays with integer ID, Tilr Name,
  system name, default space, and IODisplayUUID:

  ```
  ID  Tilr Name   System Name              Default Space  UUID
  --  ---------   -----------              -------------  ----
  1   Laptop      Built-in Retina Display  Coding         A1B2C3D4-...
  2   Left        DELL U2723QE             —              E5F6G7H8-...
  ```

- **`tilr displays configure <id>`** — update display metadata:
  - `--name <name>` — set/update Tilr Name
  - `--number <n>` — reassign integer ID
  - `--default-space <space>` — set default space (optional; display can be
    named without one)

## Implementation steps

> **Implementation order:** implement the display identity foundation first —
> `IODisplayUUID → integerID` mapping, `tilr displays list`, and
> `tilr displays configure` — before tackling space-switching across displays.
> The stable ID mapping is a prerequisite for all subsequent per-display work.

- [ ] **Display identity foundation:** on first sight of a display, read its
      `IODisplayUUID` and auto-assign the next available integer ID. Persist the
      `[IODisplayUUID: integerID]` mapping in `StateStore` so IDs survive
      hotplug/reboot. Expose user-facing Tilr Name (defaulting to "Display N").
      Implement `tilr displays list` and `tilr displays configure`.
- [ ] Audit `NSScreen.main` usages: replace with display-scoped lookups via a
      new `DisplayResolver` helper (input: space name → output: `NSScreen`).
- [ ] Extend `StateStore` to persist `[integerID: spaceName]` for current
      display→space assignment (runtime, overrides config defaults) in addition
      to the `[IODisplayUUID: integerID]` identity mapping. Migration: existing
      single-string `activeSpace` seeds `NSScreen.main`'s mapped integer ID.
- [ ] Add `DisplayService` (or extend `SpaceService`) to publish per-display
      `activeSpace` changes via Combine.
- [ ] Update `MenuBarController` — show all displays' active spaces, e.g.
      `[Coding | Reference]` or display-keyed.
- [ ] Wire `didChangeScreenParametersNotification` → re-validate display→space
      map; activate defaults for newly attached displays.
- [ ] Update `handleAppActivation` cross-space branch to switch on the app's
      *owning display*, not the current one.
- [ ] Update `moveCurrentApp` to use the target space's display frame.
- [ ] Update sidebar drag-resize and `SidebarResizeObserver` to scope ratios
      per-(display, space) instead of per-space.

## Hammerspoon-comparable behaviours checklist

- [ ] Press hotkey for Coding → activates on the display where Coding is
      configured, not the current display.
- [ ] CMD+TAB to an app on the other display → that display's space switches,
      current display stays put.
- [ ] Move app to a space on a different display → window appears on the
      correct display, framed correctly.
- [ ] Disconnect/reconnect external monitor → spaces on the disconnected
      display gracefully degrade; reattaching restores the previous mapping.

## Decisions

1. **Hotkey routing:** spaces are assigned to displays. Config holds defaults;
   runtime state (persisted in `StateStore`) holds the current assignment.
   When a space hotkey is pressed it activates on whichever display currently
   owns that space in state. The user can reassign a space to a different
   display at runtime with `CMD+SHIFT+1-n` (n = target display integer ID).

2. **Display identity:** internal stable key is `IODisplayUUID` (stored in
   state). User-facing identity is a sequential integer ID plus a Tilr Name
   (e.g. "Laptop", "Left", "Centre"). Config keys use the integer ID. State
   maps `IODisplayUUID → integerID` so the mapping survives plug/unplug. First
   time Tilr sees a display it auto-assigns the next available integer ID. The
   user can later reassign IDs and names via `tilr displays configure`.

3. **Unconfigured displays:** passive — Tilr ignores them for layout purposes.
   A display can be named via `tilr displays configure` without assigning a
   default space; `--default-space` is optional.

## Out of scope

- Per-display alert popups (single popup on the active display is fine).
- Display-aware fill-screen sizing (already uses `screen.frame` correctly).
- Delta 12 (state file) and Delta 13 (polish) — handled separately.
