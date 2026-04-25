# Delta 9b — Sidebar layout on app activate/close

**Goal:** fix sidebar-specific layout issues when sidebar-slot apps are activated
or closed. Three related problems:

1. When closing a sidebar app (e.g., Marq), the main app doesn't resize to fill
   its frame unless the space switch is retriggered.
2. When activating (opening/showing) a sidebar app, the sidebar layout isn't
   triggered — the app shows but doesn't fit into its sidebar frame.
3. When layout is triggered, vertical sizing isn't correct — the frame height
   calculation doesn't account for the hidden sidebar app's position.

The fix ensures sidebar layout (framing, resizing, reattaching drag observers) is
triggered consistently on app activation, app close, and space reactivation.

## Implementation tasks

- [ ] **Identify sidebar layout trigger points.** Document where the three issues
      originate (app activation handler, app close observer, frame calculation).
      Reference `AppWindowManager` sidebar-slot branches.

- [ ] **Unify sidebar layout logic.** Extract common sidebar framing and drag
      observer reattach logic into a shared helper method to avoid duplication
      and ensure consistency across trigger points.

- [ ] **Handle app activation.** When an app in a sidebar slot is activated
      (or shown from hidden state), call the sidebar layout helper to frame it
      and reattach drag observers.

- [ ] **Handle app close.** Register an observer for app termination and visibility
      changes. When a sidebar app closes, trigger layout on the remaining apps
      in that space (or the main app to resize into the freed frame).

- [ ] **Fix vertical sizing in frame calculation.** Review the frame calculation
      in `AppWindowManager` sidebar branches. Adjust height calculation to
      account for both main app and hidden sidebar apps.

- [ ] **Reattach drag observers.** Ensure drag observers are properly reattached
      after layout changes (on both app activation and close).

- [ ] **Verification.** Test with multi-app sidebar configs (e.g., Ghostty + Marq
      in Coding space).
      - Close Marq → Ghostty resizes to fill; reopen Marq → fits sidebar, not full screen.
      - Hide Marq in sidebar → Ghostty resizes; show Marq → fits sidebar frame.
      - Vertical height correct in both states (main app fills available height).

## References

- **`AppWindowManager`** — sidebar-slot framing and drag observer logic
  (`Sources/Tilr/AppWindowManager.swift`)
- **`NSWorkspace.didActivateApplicationNotification`** — app activation observer
  (already in place for Delta 9 cross-space switching)
- **`NSWorkspaceDidTerminateApplicationNotification`** — app close event
- **Frame calculation** — review sidebar-slot branch in `layoutApps()`

## Implementation notes

- The sidebar layout handler should run *after* the app is confirmed visible
  (avoid racing with AX readiness delay; reuse `retryUntilWindowMatches` pattern
  from Delta 8 if needed).
- Drag observer reattach is safe to call repeatedly (just ensure old observers
  are cleaned up first).
- Close handling may need to distinguish between true termination vs. user
  hide/show (visibility observer on the sidebar app window).
- Coordinate with Delta 9 cross-space switching — ensure sidebar layout runs
  for in-space activations after cross-space branch returns early.
