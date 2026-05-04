# Layout Orchestration and the Space Switch Problem

## The Five Actions That Trigger Visibility Changes

All of these actions require computing which apps should be visible and applying hide/show operations:

```
User Actions (Entry Points)
│
├─ Switch Space (hotkey/CLI)
├─ CMD+TAB to app in different space
├─ Move app from one space to another
├─ Close window (may change visible apps)
└─ Launch app (may show/hide based on space config)
│
└─→ All converge to: ORCHESTRATE VISIBILITY AND LAYOUT
```

## Desired Two-Phase Architecture

```
USER ACTION
│
├─────────────────────────────────────────────────────┐
│ PHASE 1: COMPUTE VISIBILITY INTENT                  │
│ (from config: which apps should be visible?)        │
│                                                      │
│ Input:  target space name                          │
│ Logic:  space.apps → filter visible vs hidden      │
│ Output: lists of (hideApps, showApps)              │
└──────────────────────┬────────────────────────────┘
                       │
├─────────────────────────────────────────────────────┐
│ PHASE 2: ISSUE HIDE/SHOW OPERATIONS                │
│ (execute all visibility changes in batch)          │
│                                                      │
│ hideApp(A), hideApp(B), showApp(C), showApp(D)    │
│ All issued asynchronously (fire-and-forget)        │
│                                                      │
│ State: apps transitioning (AppKit/SystemEvents     │
│        processing hide/show, AX enumerating...)    │
└──────────────────────┬────────────────────────────┘
                       │
├─────────────────────────────────────────────────────┐
│ PHASE 3: WAIT FOR VISIBILITY STABILITY             │
│ (let OS settle, AX state becomes consistent)      │
│                                                      │
│ Poll AX enumeration every 50ms                      │
│ When stable for 2+ consecutive checks → proceed    │
│ (all apps now correctly hidden or visible)         │
└──────────────────────┬────────────────────────────┘
                       │
├─────────────────────────────────────────────────────┐
│ PHASE 4: LAYOUT (Future, rebuild on stable base)   │
│ (position windows based on final visibility state) │
│                                                      │
│ Now visibility is known and stable.                │
│ Compute window frames for layout strategy.          │
│ Apply frames atomically.                            │
└─────────────────────────────────────────────────────┘
```

## Phase-Separation Benefits

- **Hide/show isolation:** Visibility logic is independent of layout logic. Fix visibility bugs without layout interference.
- **Single orchestration point:** All four actions route through the same phases. No racing between space switch and CMD+TAB reflows.
- **Stability guarantee:** Layout only runs after AX state is known to be consistent. No "Ghostty positioned while Marq still enumerated" races.
- **Easier debugging:** Enable/disable phases independently. First iteration: disable layout, just verify hide/show works. Second: rebuild layout knowing visibility is reliable.

## The Core Problem

Layout in Tilr is **reactive**: every time an app's visibility changes (hide/show), it immediately triggers a layout reflow. This creates cascading layout passes with incomplete visibility state.

Symptom: When hiding an app (e.g., Marq), Ghostty doesn't resize to fill the space. This happens because:
1. Hide Marq → reflow fires → Ghostty frame computed (Marq still in AX enumeration)
2. Hide Marq again (async SystemEvents delayed) → reflow fires → Ghostty frame re-computed (maybe Marq gone now)
3. Ghostty positioned twice with conflicting frame data, final result is incomplete

Additionally, **multiple entry points** (space switch, CMD+TAB, move app, close window, launch app) all trigger visibility changes independently. Each one goes through the reactive system, causing them to race with each other's layout computations.


## Implementation Strategy: Disable Layout First, Rebuild on Solid Base

Instead of refactoring both visibility orchestration and layout at once, **phase the work:**

### Iteration 1: Fix Visibility Orchestration (Disable Layout)

**Goal:** Get hide/show working reliably with no layout interference.

1. **Identify all reactive layout triggers** — Find everywhere layout is called as a side effect of visibility changes.
2. **Suppress them** — Comment out or guard all reactive layout calls.
3. **Single orchestration point** — Merge the five action entry points (space switch, CMD+TAB, move app, close window, launch app) into a shared handler that:
   - Computes visibility intent from config
   - Issues all hide/show ops in batch
   - Waits for AX stability
   - ~~Calls layout~~ (disabled for now)
4. **Test and verify** — Hide/show should work cleanly without layout noise interfering.

### Iteration 2: Rebuild Layout on Stable Visibility

**Goal:** Add layout back, knowing visibility state is reliable.

1. **Re-enable layout** — Restore or rebuild the layout apply phase, now running only after visibility is stable.
2. **No more reactive layout** — Layout is triggered explicitly from the orchestration point, not as a side effect.
3. **Verify window positioning** — With stable visibility, layout should produce correct frames consistently.

This two-iteration approach:
- **Isolates the visibility problem** from layout complexity
- **Lets you fix one thing at a time** (visibility orchestration, then layout application)
- **Provides a clean base** for rebuilding layout with better knowledge
- **Easier debugging** — visibility bugs won't be masked by cascading layout reflows

## Related Issues

The retry chain + self-cancel mechanism in `AXWindowHelper.swift` is sound for handling individual app hide/show. But it's fighting the layout system's reactivity. We need to:

1. Make layout **non-reactive** (explicit trigger, not event-driven)
2. Make visibility changes **transactional** (batch + wait for stability + layout)
3. Keep retry logic (still useful for individual CLI commands, e.g. `tilr apps zen hide`)

## Files Involved

**Visibility orchestration (four entry points):**
- `Sources/Tilr/AppWindowManager.swift` — Space switch (`handleSpaceActivated`), move app, close window
- `Sources/Tilr/AppWindowManager.swift` — CMD+TAB follow-focus (`handleAppActivation`, cross-space logic)
- `Sources/Tilr/CommandHandler.swift` — CLI commands (space-switch, move)

**Hide/show operations:**
- `Sources/Tilr/Layouts/AXWindowHelper.swift` — `hideApp()`, `showApp()`, retry logic

**Layout (currently reactive, target for suppression in Iteration 1):**
- `Sources/Tilr/Layouts/*.swift` — Layout strategies (`SidebarLayout`, `FillScreenLayout`)
- Wherever `reflow` or layout methods are called as side effects of visibility changes

**Reference documentation:**
- `doc/arch/window-visibility.md` — Hide/show mechanics and async timing
- `doc/arch/cross-space-switching.md` — CMD+TAB follow-focus details
- `doc/arch/async-and-races.md` — Generation tokens and async guard patterns
- `doc/bugs/bug-9-investigation-2.md` — Experiment 3 context and findings

## Next Steps for Tomorrow

1. Map the current reactive layout triggers (grep for reflow calls, where are they triggered from visibility changes?)
2. Identify the four entry points and how they currently orchestrate hide/show
3. Design the single orchestration function signature (what inputs, what outputs, what sequencing?)
4. Begin Iteration 1: suppress layout, merge entry points, implement batched + stability-checked visibility
