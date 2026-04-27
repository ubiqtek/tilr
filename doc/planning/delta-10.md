# Delta 10 — Sidebar Layout on App Activate/Close

**Goal:** keep sidebar-layout spaces visually correct as apps launch, activate,
hide, unhide, or terminate.

**Status:** done

## Scope

When the user is in a sidebar space, the layout must stay coherent as the app
lifecycle changes around it:

- **App launches** — a new instance of a sidebar-space app appears; reflow so
  it lands in the right slot.
- **App terminates** — a sidebar-space app exits; reflow so the remaining apps
  fill correctly.
- **App hides / unhides** — an OS-level hide (Cmd-H, Hide Others, etc.) fires;
  reflow to maintain the visible slot.
- **Slot activated** — the user CMD+TABs or clicks a sidebar slot app; resize
  it into its frame and hide the previous slot occupant.

Reference behaviours from Hammerspoon `init.lua`:
- `applicationDidLaunch` callback → reframe sidebar on 0.3s delay
- `applicationDidTerminate` callback → immediate reframe
- `applicationDidHide` / `applicationDidDeactivate` callbacks → reframe unless
  Tilr issued the hide itself
- Focus watcher `focusWatcher` → slot-app activation triggers frame + hide of
  previous slot occupant

## Implementation steps (see plan for detail)

- [ ] Add `ReflowReason` enum and `reflowSidebarSpace` helper in AppWindowManager
- [ ] Wire `didLaunchApplicationNotification` → reflow with 0.3s delay
- [ ] Wire `didTerminateApplicationNotification` → immediate reflow
- [ ] Wire `didHideApplicationNotification` / `didUnhideApplicationNotification`
      → reflow with hide-event suppression
- [ ] Refactor `handleAppActivation` sidebar branch to use `reflowSidebarSpace`
- [ ] Add entry-log line in each handler for `just logs-capture` greppability

## Hammerspoon-comparable behaviours checklist

- [ ] Launch → sidebar reflows with correct slot occupant after app appears
- [ ] Terminate → sidebar reflows immediately, remaining apps fill correctly
- [ ] Cmd-H hide → sidebar reflows; Tilr-issued hides are suppressed (no loop)
- [ ] Unhide → sidebar slot reoccupied correctly
- [ ] CMD+TAB slot activation → slot resized, previous slot occupant hidden
- [ ] No double-reflow when Tilr issues hide as part of a reflow

## Open questions

1. Should `reflowSidebarSpace` activate (focus) the main app when a slot app
   terminates, or leave focus where macOS places it?
2. If a non-sidebar app terminates while we're in a sidebar space, we skip
   the reflow — correct to keep same skip logic?

## Bugfix: Live space membership

**Problem observed:** After moving Zen into Coding via `tilr move-current` (or hotkey), clicking Marq (the configured slot app) does not hide Zen. Both apps remain visible.

**Root cause:** `isMemberOfActiveSidebarSpace(bundleID:)` checks `space.apps` from config, which only contains *pinned* apps. Zen is pinned to Reference, not Coding, so:

1. Click Zen in Coding → activation handler returns early (filtered out as non-member)
2. `previousSidebarSlotApp[Coding]` never gets set to Zen
3. Click Marq → handler runs, but no previous slot app to hide
4. Zen stays visible

Before Delta 10, the original sidebar branch ran for any frontmost app and consulted `previousSidebarSlotApp` directly without a config-based filter — which is why this worked previously.

**Conceptual fix:** Distinguish two concepts:

- `space.apps` in config = where apps *open* by default (pinning)
- Runtime live membership = which apps *currently inhabit* the space (mutable)

The runtime live membership is exactly the shape we'll persist to `state.toml` in Delta 12. Building it in memory now means Delta 12 just adds load/save plumbing.

### Implementation

Add `liveSpaceMembership: [String: Set<String>]` (spaceName → bundle IDs) to `AppWindowManager`. In-memory only for Delta 10.

**Mutations:**
- **Init:** seed from config — every pinned app maps to its pinned space
- **`moveCurrentApp`:** remove from source space's set, add to target's
- **`didLaunch`:** add to pinned space (covers fresh launches)
- **`didTerminate`:** remove from all spaces

**Reads:**
- `isMemberOfActiveSidebarSpace` body checks `liveSpaceMembership[currentSpaceName]?.contains(bundleID)`
- `SidebarLayout` reads slot candidates from live membership; main app stays fixed from config; `previousSidebarSlotApp` decides which slot candidate is visible

### Implementation steps
- [x] Add `liveSpaceMembership` ivar and seed from config in `AppWindowManager.init()`
- [x] Update on `moveCurrentApp` (remove from source, add to target)
- [x] Update on `didLaunch` notification handler (add to pinned space)
- [x] Update on `didTerminate` notification handler (remove from all)
- [x] Replace `isMemberOfActiveSidebarSpace` body to use live membership
- [x] Update `SidebarLayout` to read slot candidates from live membership (via `liveAppsOverride`)
- [x] Also fixed `handleAppActivation` sidebar branch filter (same config-only issue)
- [ ] Verification: move Zen into Coding, click Zen → Marq, confirm Marq frames and Zen hides

## Regression fix: slot activation race condition

**Problem observed:** After moving Zen into Coding, CMD+TABing to Marq did not hide Zen.

**Investigation found two issues:**

### Issue 1: Activation suppression in moveCurrentApp (partial fix, not sufficient)

The 0.25s delayed block in `moveCurrentApp` tried to activate the moved app while `isTilrActivating = true` (from `handleSpaceActivated`'s 0.6s window). The activation notification was therefore filtered out by the `guard !isTilrActivating` check, so `previousSidebarSlotApp` never got set.

Removed the `app.activate()` block from `moveCurrentApp` (lines 282–290 in the 0.25s delayed block). The layout is already applied; programmatic focus isn't needed.

### Issue 2: Reflow debounce collapsing slot-activated into app-unhidden (the real culprit)

When the user CMD+TABs to a slot app, **two** reflow events queue:
1. `.slotActivated` from `handleAppActivation` (activation notification)
2. `.appUnhidden` from `didUnhideApplicationNotification` (macOS unhides the app during activation)

The `reflowSidebarSpace` debouncer (`pendingReflowWorkItem?.cancel()`) cancels the first and runs the second. The `.appUnhidden` path goes through `applyLayout` → `applySidebarSwitch`, which only sets frames — it never hides the previous slot app. **Only `.slotActivated` calls `setAppHidden(prev, hidden: true)`.** Cancelling it means the hide never happens.

**Fix:** Added `unhideEventSuppression` table mirroring the existing `hideEventSuppression` pattern. In `handleAppActivation`'s sidebar branch, call `suppressUnhideEvent(for: bundleID)` just before triggering the slotActivated reflow. The unhide observer skips suppressed events, so only `.slotActivated` runs through the debouncer.

**Verification:** [x] Move Zen into Coding, CMD+TAB to Marq — Marq frames and Zen hides ✓

## Regression fix: stale ratio on slot activation

**Problem observed:** After dragging the sidebar boundary in the visible slot app, CMD+TABing to a hidden slot app brought it up at the OLD pre-drag size, not the new ratio.

**Root cause:** In `reflowSidebarSpace`'s `.slotActivated` branch, a `wasHidden` check determined whether to apply the frame immediately or after a 0.2s delay with a retry loop. But the check ran 150ms after activation (inside the debounced work block), by which time macOS had already finished unhiding the app — so `wasHidden` was always `false`. The else branch had a single `setFrameAndSuppress` call with no retry. Browsers like Zen routinely ignore the first AX setFrame after unhide and assert their AppKit-restored frame back, so the new ratio got dropped on the floor.

A secondary issue (defence-in-depth, not the proximate cause): `SidebarResizeObserver` stores `hiddenSidebarBundleIDs` but never iterates them during drag-settle, so hidden slot apps never receive the new frame during a drag. Deferred — fix #1 above is sufficient on its own.

**Fix:** Removed the `wasHidden` branching entirely and always run the retry loop on slot activation. The retry short-circuits cheaply when the window already matches the target size, and self-heals when the app ignores the first AX call.

**Verification:** [ ] Drag sidebar boundary in Marq, CMD+TAB to Zen — confirm Zen comes up at the new ratio, not the old one.

## Status summary (committable state)

The core sidebar lifecycle behaviours work: CMD+TAB between slot apps swaps frame and hide cleanly; quitting a slot app expands main to full screen; re-launching brings the app back at the right size (width + height). Steady-state operation is solid.

The remaining issues all share a shape: **transient initialization races during transitions**. The system is eventually consistent — once it settles, it works. These are accepted as edge cases for now rather than chased symptom-by-symptom.

### What's working

- **Slot toggling (CMD+TAB between slots):** previous slot app hides, new slot app frames into the slot. Self-healing via retry loop on width AND height.
- **Slot drag-resize:** ratio updates apply to visible main + sidebar; observer state is per-space and survives reattach.
- **App quit → main expands:** terminate observer captures membership before mutation, fires reflow correctly.
- **App re-launch:** trigger-app retry ensures the relaunched app reaches its slot frame even if it ignores the first AX call.
- **Move-into a sidebar space:** moved app frames into slot, previous slot occupant hides on next CMD+TAB.

### Known edge cases (deferred)

- **Layout not applied on wake from sleep:** When the laptop wakes from sleep mode, the sidebar layout is not reapplied — the space's windows appear in their previous positions without re-flowing to the configured layout. Likely needs to hook into a macOS wake notification or check layout state on space reactivation.
- **Intermittent startup miss-frame:** On occasional Tilr restarts, the slot app doesn't resize correctly on first space activation. A second restart fixes it. Likely an AX/window-readiness timing race during startup.
- **Gap on right after move-into + drag-resize with browser slot app:** When Zen is the slot app and the user drags the boundary, a gap can appear on the right side of the screen. Root cause identified: the resize-settle work item in `SidebarResizeObserver` skips reframing the dragged sidebar (`where sid != capturedDragged`). Compliant apps (Marq) preserve their right-edge anchor so this doesn't matter; browsers (Zen) don't, leaving a gap. One-line fix queued: remove the filter so the dragged sidebar gets reframed to the canonical `sidebarFrame`.
- **Re-launching a slot app while another slot app is visible doesn't hide the visible one:** When Marq re-launches into Coding while Zen is currently visible in the slot, both stay visible. Root cause: the lifecycle-driven full-reapply path (`.appLaunched` → `applySidebarSwitch`) only sets frames; it never consults `previousSidebarSlotApp` or hides the previous slot occupant. Only the `.slotActivated` path does that. Design gap, not a recent regression.
- **Moving the main window out of a sidebar space:** Using `tilr move-current` (or hotkey) to move the main app of a sidebar layout (e.g. Ghostty out of Coding) into another space (e.g. Reference) didn't work as expected. Needs investigation — likely interacts with `layout.main` being treated as fixed in the sidebar layout and the move-out path's assumptions about which app is leaving.

### Underlying design gap

The reflow paths split into two kinds of work:
1. **Slot-activated** (`.slotActivated`) — frames new slot app, hides previous, updates `previousSidebarSlotApp`.
2. **Lifecycle full-reapply** (`.appLaunched`, `.appTerminated`, `.appHidden`, `.appUnhidden`) — calls `applyLayout` → `applySidebarSwitch`, which only sets frames; never hides previous slot.

The remaining edge cases concentrate in the second path. A future cleanup could either:
- Have lifecycle reflows also consult `previousSidebarSlotApp` and hide non-visible slot candidates, or
- Have `applySidebarSwitch` enforce single-slot-visible invariant by hiding all sidebar candidates except the most recently activated one.

Deferred — current behaviour is acceptable since users typically CMD+TAB after launch, which fires `.slotActivated` and self-corrects.

## Next steps / roadmap

The Delta 10 deferred edge cases are *not* the next delta — they're folded
into Delta 13 (Polish). Delta 11 (multi-display) and Delta 12 (state file)
were already planned in `plan.md` and take priority.

### Delta 11 — Multi-display support
Per-display active space, per-display layout, hotkey routing across
displays. See [`delta-11.md`](delta-11.md).

### Delta 12 — State file
Persistence of `activeSpace` (per-display), `liveSpaceMembership`,
`sidebarRatios`, and fill-screen focus history to
`~/Library/Application Support/tilr/state.toml`. The in-memory
`liveSpaceMembership` introduced in Delta 10 is already in the right shape;
Delta 12 just adds load/save plumbing. See [`delta-12.md`](delta-12.md).

### Delta 13 — Polish
All Delta 10 deferred edge cases (gap on right, startup miss-frame,
re-launch slot visibility, main-window move-out, wake-from-sleep) plus
standard polish (config hot-reload, launch-at-login, app icon, About).
See [`delta-13.md`](delta-13.md).

### Delta 14 — Release on App Store
App Store Connect setup, sandboxing audit, code signing, submission. See
[`delta-14.md`](delta-14.md).

## Reference comparison

### Behaviours matched vs. Hammerspoon

| Behaviour | HS Approach | Tilr Delta 10 | Status |
|-----------|-----------|-----------|--------|
| **App launch** | 0.3s delay, call `applyLayout` | 0.3s delay, `reflowSidebarSpace(.appLaunched)` → full reapply | ✓ Matched |
| **App terminate** | Immediate `applyLayout` | Immediate `reflowSidebarSpace(.appTerminated)` | ✓ Matched |
| **Cmd-H hide** | No explicit suppression | `hideEventSuppression` table (0.5s TTL) | ✓ Better (explicit) |
| **Unhide** | No explicit suppression | `unhideEventSuppression` table (0.5s TTL) | ✓ Better |
| **Slot activation** | Focus-watcher auto-activates space | `handleAppActivation` sidebar branch, `reflowSidebarSpace(.slotActivated)` | ✓ Matched |
| **Cross-space follow-focus** | `activatingSpace` bool (0.5s) | `isTilrActivating` bool (0.6s) | ✓ Matched |
| **Previous slot hiding** | Implicit (layout enforces single visible) | Explicit `previousSidebarSlotApp` + hide call | ✓ Comparable |
| **Live membership** | `sessionAppOverride` (move, session-only) | `liveSpaceMembership` map (move, launch, terminate) | ✓ Better (persistent-ready) |

### Race condition strategy divergence

**Hammerspoon:**
- **Feedback loop prevention**: Relies on boolean flags with manual reset windows (`activatingSpace`, `ignoringResize`, both 0.5s fixed)
- **Window placement retry**: Single `placeWindow` call; logs delta warning but does not retry
- **Slot switching**: Implicit in layout — if main and sidebar both visible, main wins; only sidebar shows if main absent

**Tilr:**
- **Feedback loop prevention**: Time-keyed suppression tables (0.5s TTL) pruned on each access; generation counters detect stale completions
- **Window placement retry**: `retryUntilWindowMatches` loop (width+height comparison, ~100ms polls) repeats until size matches or generation stales
- **Slot switching**: Explicit `previousSidebarSlotApp` tracking; `.slotActivated` branch always hides previous slot and runs retry loop for new one
- **Reflow debounce**: 0.15s coalesce window for rapid successive events (launch/unhide/activate within 150ms)

**Why the differences:**
1. **Retry loop**: Hammerspoon assumes single `placeWindow` succeeds; Tilr discovered browsers (Zen) ignore first AX `setFrame` after unhide, requiring retry. HS avoids this by not unhiding on app activation — only on space-switch.
2. **Suppression tables vs. flags**: Tilr's time-keyed tables handle the `.appUnhidden` race case — two reflow events queue (`.slotActivated` + `.appUnhidden`), and unhide suppression ensures only `.slotActivated` fires. HS doesn't face this because its focus-watcher doesn't trigger on unhide, only on activation.
3. **Explicit slot tracking**: HS layout logic infers single-visible from `#sidebarWins` count at layout-apply time. Tilr made it explicit with `previousSidebarSlotApp` to simplify the `.slotActivated` branch and ensure the previous slot always hides (even if the next reflow reason is lifecycle-driven instead of slot-activation).

### Design insights for deferred edge cases

1. **"Layout not applied on wake from sleep"**: HS has no explicit wake handler either — it would behave identically (space layout not reapplied on wake). Suggests this may be a macOS Spaces limitation (Spaces themselves don't emit wake notifications). Consider registering for `NSWorkspace.didWakeNotification` or polling space membership on first app activation post-wake.

2. **"Re-launching a slot app while another slot app is visible"**: Root cause (documented in delta-10.md already) — lifecycle paths call `applyLayout` → `applySidebarSwitch` (frames only), never hide previous slot. HS avoids this by layering: `applyLayout` rebuilds sidebarWins set, then layout logic enforces single-visible. Tilr could adopt the same pattern or extend lifecycle paths to explicitly hide non-previous slot candidates.

3. **"Intermittent startup miss-frame"**: HS uses fixed 0.2s delay post-frame; Tilr uses polling. Both are vulnerable to early AX read (window not yet registered by the app). HS logs the delta; Tilr retries. Consider a hybrid: initial delay + retry loop (gives time for window to settle, then auto-corrects ignores).

4. **"Gap on right after move-into + drag-resize"**: Tilr identified the root cause (line ~154 of delta-10.md, `where sid != capturedDragged` filter). One-line fix already queued. HS avoids this because `SidebarResizeObserver` equivalent uses a simpler `ignoringResize` flag without tracking which window was dragged.

### Debounce & generation tracking

HS does not track generation or debounce reflows — each event schedules its own work immediately (with fixed delays). Tilr's debounce + generation approach gives better coalescence of rapid events (e.g., launch + unhide + activate within 150ms all become one reflow) and stale-check safety across async boundaries.

**Recommendation**: The generation-based stale-check is sound; keep it. The 0.15s debounce interval is aggressive (responsive) but may need tuning if rapid event bursts cause missed updates — monitor logs for `"reflow dropped (generation stale)"` patterns.
