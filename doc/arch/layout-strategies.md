# Layout Strategies

How Tilr positions windows after unhiding them — sidebar layout for main + sidebar apps, fill-screen layout for single-app spaces.

## Overview

After a space is activated and its apps are unhidden, Tilr applies one of two layout strategies to position windows:

- **Sidebar layout** — Main app on the left (default 65% width), sidebar apps stacked in right column (35%).
- **Fill-screen layout** — All visible apps positioned to full screen (overlapped, z-order preserved).

Both strategies use the Accessibility Framework (`AXUIElement`) to read/write window frames. If AX is not trusted, layout gracefully degrades to hide/show only (logged at `.info`).

## Sidebar layout

### Ratio and position calculation

The main app's width is determined by a ratio (default 0.65), customizable per-space:

```
mainWidth = ratio * screenWidth
mainFrame = (0, 0, mainWidth, screenHeight)
sidebarX = mainWidth
sidebarFrame = (sidebarX, 0, (1-ratio)*screenWidth, screenHeight)
```

**Resolution order for ratio:**
1. Session override dict (set by `SidebarResizeObserver` after drag-to-resize).
2. Per-space config override (`config.spaces[spaceName].layout.ratio`).
3. Global default (0.65).

### Sidebar app stacking

All non-main apps in a sidebar space are positioned to the right column at the same frame (`sidebarFrame`). They overlap, and the z-order is preserved (whoever was frontmost stays frontmost). This allows cmd-tabbing between sidebar apps without repositioning.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/SidebarLayout.swift:apply()` computes frames and calls `AXWindowHelper.setWindowFrame()`.

### Ratio persistence

Session-only (memory dict, cleared on app restart) during Delta 0–8. Delta 9 will persist to `state.toml`, allowing ratios to survive app restart.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/SidebarResizeObserver.swift:52` — session dict definition.

## Fill-screen layout

### Positioning

All apps in a fill-screen space are positioned to the full screen frame:

```
fullScreenFrame = NSScreen.main.frame
for app in visibleApps {
    AXWindowHelper.setWindowFrame(app, fullScreenFrame)
}
```

They overlap at full screen, z-order preserved. Only the user's last-focused app is visible; others are hidden via `setAppHidden()` (AX hide, not NSRunningApplication hide).

### Last-focused app tracking

`AppWindowManager.fillScreenLastApp[spaceName]` tracks the user's current app in a fill-screen space:

- On space activation, restore the previous session's focus or use `layout.main` or first app.
- On cmd-tab to a fill-screen app, update `fillScreenLastApp` and hide the previous app.
- On space switch to fill-screen, hide all but the current focus.

**Code reference:**
- Initialization on space switch: `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:270-279`
- Update on cmd-tab: `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:198-212`

## AX trust and graceful degradation

At layout apply time, we check `AXIsProcessTrusted()`:

```swift
if !AXIsProcessTrusted() {
    Logger.layout.info("AX not trusted, skipping frame positioning")
    return  // hide/show still worked, space is functional
}
```

If AX is not trusted (user hasn't granted Accessibility permission in System Settings), layout is skipped with a `.info` log message. Hide/show still works, so the space is functional — just without window positioning. No error, no retry, no breaking the user experience.

## Timing: apply after hide/unhide

Layout is applied ~200ms after hide/unhide to allow AX window readiness:

```
T=0: hide/unhide apps
T=0-200ms: OS processes, AX windows become accessible
T=200ms: schedule layout.apply()
```

See [Window Visibility](./window-visibility.md) for details on why this timing is necessary.

## Observer setup

After layout apply, `SidebarLayout` attaches an `AXObserver` to the main and sidebar apps for drag-to-resize:

```swift
observer.attach(apps: mainApp + sidebarApps, spaceName: spaceName)
```

The observer watches for `kAXResizedNotification` and recomputes the sidebar ratio on each drag. A re-entrance guard (`ignoringResize` flag) prevents our own `setFrame` calls from triggering observer callbacks. The guard clears after 500ms (tuned empirically in Hammerspoon).

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/SidebarResizeObserver.swift:attach()`.

## Drag-to-resize (sidebar only)

When the user drags the right edge of the main sidebar app:

1. Observer fires `kAXResizedNotification`.
2. Read the main app's new width.
3. Compute new ratio: `ratio = newWidth / screenWidth`.
4. Clamp to [0.1, 0.9] (prevent pathological layouts).
5. Store ratio in session dict.
6. Set `ignoringResize = true` to suppress echo events.
7. Call `setFrame` on sidebar apps to match new position.
8. Schedule clear of `ignoringResize` flag at T+500ms.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/SidebarResizeObserver.swift:handleResize()`.

## Special case: sidebar move-into

When moving a sidebar-slot app to a new sidebar space, the target space's layout is applied immediately (T+200ms settle, not the default ~350ms). The moved app is pre-sized to its target frame *before* hiding from the old space, so it unhides into the correct size when the move completes.

See [Move Window to Space](./move-window-to-space-flow.md) for full details.

## Visibility: layout only applies to visible apps

Layout skips hidden apps. When computing `visibleApps`:

```swift
let visibleApps = space.apps.filter { !isAppHidden(bundleID: $0) }
sidebarLayout.apply(visibleApps: visibleApps, ...)
```

This avoids framing hidden apps (which are AX-inaccessible anyway) and reduces unnecessary AX calls.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/FillScreenLayout.swift:apply()` — filters to visible apps before positioning.

## Related docs

- [Space Switching](./space-switching.md) — When layout is applied
- [Window Visibility](./window-visibility.md) — Hide/unhide timing
- [Drag-to-Resize Sidebar](./sidebar-drag-resize.md) — Observer details
- [Move Window to Space](./move-window-to-space-flow.md) — Pre-move sizing
- [Cross-Space Switching (Delta 9)](./cross-space-switching.md) — Visibility during CMD+TAB

## Implementation checklist

- [x] Sidebar layout (main + sidebar apps)
- [x] Fill-screen layout (single-app fullscreen)
- [x] AX trust check and graceful degradation
- [x] Layout defer after hide/unhide (~200ms)
- [x] AX observer for drag-to-resize (sidebar only)
- [x] Session ratio persistence (memory)
- [ ] Persistent ratio persistence to `state.toml` (Delta 9)
- [ ] Per-display layout (multi-display, Delta 10+)
