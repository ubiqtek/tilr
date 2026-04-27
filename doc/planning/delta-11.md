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
- **Per-display hotkeys:** hotkey activation routes the space switch to the
  display whose mouse cursor is over it (or active display, TBD — see open
  questions).
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

## Implementation steps

- [ ] Audit `NSScreen.main` usages: replace with display-scoped lookups via a
      new `DisplayResolver` helper (input: space name → output: `NSScreen`).
- [ ] Extend `StateStore` to persist `[displayUUID: spaceName]` instead of a
      single `activeSpace`. Migration: existing single-string state seeds
      `NSScreen.main`'s UUID.
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

## Open questions

1. Hotkey routing: should a hotkey always switch the display where the
   space is *configured*, or the display under the mouse cursor?
   (Hammerspoon does the former — config-driven.)
2. Display identity across reboots: `CGDirectDisplayID` is unstable;
   `NSScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]` or
   the IODisplayUUID? Choose one and document why.
3. What happens if the user has only one display configured but two physical
   displays? Default space activates on primary; secondary is "passive" until
   the user adds it to config.

## Out of scope

- Per-display alert popups (single popup on the active display is fine).
- Display-aware fill-screen sizing (already uses `screen.frame` correctly).
- Delta 12 (state file) and Delta 13 (polish) — handled separately.
