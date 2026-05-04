# Delta 13 — Polish

**Goal:** clean up the deferred edge cases and rough corners discovered during
Delta 10, plus the standard "shippable starter" polish (icon, About dialog,
launch-at-login, config hot-reload).

**Status:** planned

**Depends on:** Delta 12 (state file). Several edge cases below are easier to
fix once persistence is in place.

## Scope

### A. Deferred edge cases from Delta 10

#### A1. Gap on right after drag-resize with browser slot app *(quick win)*

When Zen (or other browser) is the slot app and the user drags the sidebar
boundary, a gap appears on the right edge.

**Root cause:** `SidebarResizeObserver` resize-settle work item filters out
the dragged sidebar (`where sid != capturedDragged`). Compliant apps (Marq)
preserve their right-edge anchor; browsers don't, leaving a gap.

**Fix:** remove the filter so the dragged sidebar gets reframed to the
canonical `sidebarFrame`. ~5 minutes, one line.

**Location:** `Sources/Tilr/Layouts/SidebarResizeObserver.swift`,
resize-settle work item.

#### A2. Intermittent startup miss-frame *(medium effort)*

On occasional Tilr restarts, the slot app doesn't resize correctly on first
space activation; a second restart fixes it. AX/window-readiness timing race
during startup.

**Fix approach:**
- Add a startup delay (~0.5s) before the first reflow to let AX/window
  system settle.
- Validate the existing retry loop self-heals when the app ignores the
  first AX call.

**Locations:** `AppWindowManager.swift` (init / first-space activation),
`SidebarLayout.swift` (retry generation tracking).

#### A3. Re-launching slot app while another is visible *(design gap)*

When Marq re-launches into Coding while Zen is currently visible in the
slot, both stay visible.

**Root cause:** lifecycle reflow paths (`.appLaunched`, `.appTerminated`,
`.appHidden`, `.appUnhidden`) only set frames; never consult
`previousSidebarSlotApp` or hide non-visible slot candidates. Only the
`.slotActivated` path enforces single-visible-slot.

**Fix options (pick one — discuss before implementing):**
- **Option A:** lifecycle reflows also call `setAppHidden(prev, hidden:
  true)` for inactive slot candidates.
- **Option B:** `applySidebarSwitch` itself enforces single-visible-slot
  invariant — hides all sidebar candidates except the most recently
  activated one. (Cleaner: invariant lives in one place.)

#### A4. Moving the main window out of a sidebar space *(design gap)*

`tilr move-current` to move the main app of a sidebar layout (e.g. Ghostty
out of Coding) into another space doesn't work as expected. `layout.main`
is treated as fixed.

**Investigation needed:**
1. Reproduce: capture exact symptom (no-op? wrong frame? logs?).
2. Trace `moveCurrentApp` path when the main app is the moving app.
3. Decide: is "main is fixed" a deliberate constraint (then surface a clear
   user error) or an oversight (then support it)?

#### A5. Layout not applied on wake from sleep *(low priority)*

When the laptop wakes, sidebar layout is not reapplied — windows stay in
their pre-sleep positions.

**Fix approach:**
- Hook `NSWorkspace.didWakeNotification` (or
  `NSWorkspace.didBecomeActiveNotification`).
- On wake, reapply layout for the active space on each display.
- Hammerspoon has no explicit handler; we may be the first to need one.

### B. Standard polish (from starter-app-plan §Delta 7)

- [ ] Config file watch → hot reload on save (currently requires `tilr
      reload-config`).
- [ ] Launch at login via `SMAppService`.
- [ ] App icon — Ubiqtek-branded, light/dark variants.
- [ ] About dialog: version, build, link to repo, credits.
- [ ] Menu-bar dropdown: list spaces, click to activate, "Reload config",
      "Quit".

## Implementation order

Suggested batching to minimise context-switching:

1. **A1 first** (quick win, ~5 min) — gets the most-visible bug out of the
   way.
2. **A2 next** (startup timing) — independent of design decisions; bounded
   scope.
3. **A3 + A4 together** (design-gap pair) — both concern the lifecycle vs.
   slot-activated split; fixing one informs the other.
4. **A5 last** (wake-from-sleep) — needs the most experimentation.
5. **B (standard polish)** — interleave or save for the end; mostly
   independent of A.

## Open questions

- A2: is 0.5s the right startup delay, or should it be config-driven?
- A3: Option A or B? (Lean toward B — invariant in one place.)
- A4: support main-window move, or surface a clear "main can't move"
  error? Depends on user mental model.
- A5: should wake handler reapply *all* spaces (one per display) or only
  the currently active ones?

## Out of scope

- Sandboxing / App Store entitlements — Delta 14.
- New layout strategies (grid, BSP) — future delta if/when needed.
