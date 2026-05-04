# Delta 11 — Multi-display support

**Goal:** make spaces and layouts per-display, so users with multiple monitors can have an independent active space (and layout) on each screen.

**Status:** in progress — currently on step 3 (record current space per display).

## Implementation steps

| # | Step | Status | Notes |
|---|------|--------|-------|
| 1 | Display identity foundation | ✅ done | Auto-assign integer ID from IODisplayUUID. Added `tilr displays identify` and `tilr displays config`. |
| 2 | Refactor to `DisplayResolver` shim | ✅ done | Replaced 6 `NSScreen.main` call sites in `AppWindowManager`. Resolver returns `.main` for now — no behavior change. (done 2026-05-02) |
| 3 | Record current space per display | ⬜ not started | Add `currentSpacePerDisplay: [Int: String]` to `DisplayState`. `SpaceService` writes it on every switch. `tilr displays list` gains a "Current Space" column. Still no behavior change — pure observation. |
| 4 | Resolve owning display from state | ⬜ not started | `DisplayResolver` consults `currentSpacePerDisplay`, falls back to config `defaultSpace`. First step where multi-display routing actually works. |
| 5 | Update `MenuBarController` | ⬜ not started | Show all displays' active spaces. |
| 6 | Wire `didChangeScreenParametersNotification` | ⬜ not started | Re-validate display→space map on hotplug. |
| 7 | Update `handleAppActivation` | ⬜ not started | Switch on app's owning display, not current one. |
| 8 | Update `moveCurrentApp` | ⬜ not started | Use target space's display frame. |
| 9 | Update sidebar drag-resize | ⬜ not started | Scope ratios per-(display, space). |

## End-state flow

When the user presses a space hotkey after all 9 steps are complete:

1. User presses hotkey for space "Coding"
2. `HotKeyManager` calls `SpaceService.switchToSpace("Coding", reason: .hotkey)`
3. `SpaceService` asks `DisplayResolver` which display owns "Coding". Resolution order: (a) `DisplayState.currentSpacePerDisplay` reverse-lookup (which display is currently showing "Coding"?), (b) config `displays[id].defaultSpace` (which display has "Coding" as its default?). First match wins.
4. `SpaceService` updates `activeSpacePerDisplay[displayID] = "Coding"` and persists via `DisplayStateStore`
5. `SpaceService` fires `onSpaceActivated((name: "Coding", displayID: 2, reason: .hotkey))` — note the new `displayID` field
6. `AppWindowManager.handleSpaceActivated` receives the event, calls `DisplayResolver.screen(forSpace: "Coding")` to get the right `NSScreen`
7. `LayoutStrategy.apply(screen:)` lays out windows on that display's frame — the other display is untouched
8. `MenuBarController` updates to show both displays' active spaces (e.g. `[Coding | Reference]`)

**Compare to today:** `DisplayState.currentSpacePerDisplay` doesn't exist, `SpaceService.activeSpace` is a single string with no display key, `DisplayResolver` doesn't exist (every layout uses `NSScreen.main`).

## Background

Tilr currently hardcodes `NSScreen.main` everywhere — every layout, every space switch, every frame computation assumes a single display. The config already has a `displays` section with per-display default spaces, but the runtime ignores it.

**Reference docs:**
- `doc/arch/space-switching.md` §"Multi-display (future)"
- `doc/arch/state-and-config.md` §"Per-display active space"
- Hammerspoon `init.lua` — search for `screen` / `screens()` for the reference per-display behaviour

## Scope

- **Per-display active space:** replace single `activeSpace` with a map keyed by display identifier (UUID or persistent ID). `SpaceService` and `StateStore` must read/write per-display.
- **Display-scoped space lookup:** when activating a space, find the display that owns it (via config `displays` map) and apply layout to that display's `NSScreen`, not `NSScreen.main`.
- **Per-display hotkeys:** hotkey activation routes to whichever display currently owns that space in runtime state. User can reassign a space to a different display at runtime via `CMD+SHIFT+1-n` (n = display integer ID).
- **Per-display layout:** `LayoutStrategy.apply` already takes a `screen: NSScreen` parameter; audit all callers to ensure the correct screen is passed (not `NSScreen.main`).
- **Cross-space follow-focus on target display:** when CMD+TAB activates an app whose space lives on a different display, switch that display's active space — don't drag the app to the current display.
- **Move-to-space across displays:** `tilr move-current` must respect the target space's owning display. Window move + reframe happens on that display's frame.
- **Display hotplug:** handle `NSApplication.didChangeScreenParametersNotification` — re-resolve display→space mapping when monitors are connected/disconnected.

## CLI surface (done)

`tilr displays list` — show all known displays with integer ID, Tilr Name, system name, default space, and IODisplayUUID:

```
ID  Tilr Name   System Name              Default Space  UUID
--  ---------   -----------              -------------  ----
1   Laptop      Built-in Retina Display  Coding         A1B2C3D4-...
2   Left        DELL U2723QE             —              E5F6G7H8-...
```

`tilr displays configure <id>` — update display metadata:
- `--name <name>` — set/update Tilr Name
- `--number <n>` — reassign integer ID
- `--default-space <space>` — set default space (optional; display can be named without one)

## Hammerspoon-comparable behaviours checklist

- [ ] Press hotkey for Coding → activates on the display where Coding is configured, not the current display.
- [ ] CMD+TAB to an app on the other display → that display's space switches, current display stays put.
- [ ] Move app to a space on a different display → window appears on the correct display, framed correctly.
- [ ] Disconnect/reconnect external monitor → spaces on the disconnected display gracefully degrade; reattaching restores the previous mapping.

## Decisions

1. **Hotkey routing:** spaces are assigned to displays. Config holds defaults; runtime state (persisted in `StateStore`) holds the current assignment. When a space hotkey is pressed it activates on whichever display currently owns that space in state. The user can reassign a space to a different display at runtime with `CMD+SHIFT+1-n` (n = target display integer ID).

2. **Display identity:** internal stable key is `IODisplayUUID` (stored in state). User-facing identity is a sequential integer ID plus a Tilr Name (e.g. "Laptop", "Left", "Centre"). Config keys use the integer ID. State maps `IODisplayUUID → integerID` so the mapping survives plug/unplug. First time Tilr sees a display it auto-assigns the next available integer ID. The user can later reassign IDs and names via `tilr displays configure`.

3. **Unconfigured displays:** passive — Tilr ignores them for layout purposes. A display can be named via `tilr displays configure` without assigning a default space; `--default-space` is optional.

## Out of scope

- Per-display alert popups (single popup on the active display is fine).
- Display-aware fill-screen sizing (already uses `screen.frame` correctly).
- Delta 12 (state file) and Delta 13 (polish) — handled separately.

## Technical debt / follow-up

- [ ] Refactor logging: consolidate dual-write pattern (Logger.X + TilrLogger) into a single call site — currently every log line that needs to appear in tilr.log must call both OSLog and TilrLogger separately, which caused a hide-path instrumentation gap (BUG-9). Consider a wrapper that writes to both.
