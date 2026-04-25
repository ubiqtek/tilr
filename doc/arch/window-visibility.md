# Window Visibility: Hide and Unhide

How Tilr uses `NSRunningApplication.hide()` and `unhide()` to control which apps are visible in the active space.

## Overview

Tilr does not use macOS's native Spaces or Mission Control APIs. Instead, it models "spaces" as named app groupings and implements activation via **hide/unhide** — showing all apps in the active space, hiding all others. Combined with optional window positioning via the Accessibility Framework, this gives the illusion of separate workspaces.

**Why this model?**
- Simple and portable: no private CGS APIs or Mission Control integration.
- Works across displays: visibility is per-app, not per-app-per-display (simpler for now).
- Matches the Hammerspoon POC exactly.

## Timing invariants

### Hide/unhide is asynchronous

When you call `NSRunningApplication.hide()`, the OS makes the app invisible and its windows are no longer accessible to AX. This doesn't happen synchronously in the current thread; it's queued and happens "soon." Same with `unhide()` — AX window readiness is delayed ~200ms post-unhide.

**Implication:** Layout applies *after* hide/unhide to avoid calling AX `setFrame` on inaccessible windows.

```swift
// Timeline:
// T=0: call hide/unhide on all apps
// T=0-200ms: OS processes hide/unhide, AX windows become inaccessible/accessible
// T=200ms: schedule layout apply (safe to call setFrame)
```

### Hidden apps are AX-inaccessible

When an app is hidden, its main AX window becomes inaccessible — only modal dialogs remain. This causes AX calls to fail silently.

**Workaround for sidebar moves:** When moving a sidebar-slot app to a new space, we pre-resize it *before* hiding it (from its old space). When the user later cmd-tabs to it, it unhides already at the correct size, avoiding a second `setFrame` call that might fail due to AX inaccessibility.

**Workaround for activation-time framing:** When cmd-tabbing to a sidebar-slot app that was hidden, we add an extra 200ms delay before calling `setFrame` to wait for AX readiness (see `handleAppActivation` in AppWindowManager).

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:241-256` — the `wasHidden` branch that defers frame application by 200ms.

## Hide/show logic in space switch

When switching spaces, `AppWindowManager` computes two sets:
- **allSpaceApps** — union of all configured-space apps (from config)
- **thisSpaceApps** — apps in the target space (from config)

Then:
```swift
for app in NSWorkspace.shared.runningApplications {
    let bundleID = app.bundleIdentifier ?? ""
    if thisSpaceApps.contains(bundleID) {
        app.unhide()
    } else if allSpaceApps.contains(bundleID) {
        app.hide()
    }
    // Apps not in any space (Finder, System Settings, etc.) are left as-is.
}
```

The union ensures even not-currently-running apps are candidates for hiding if they were ever configured in a space.

## Visibility and layout

After hide/unhide completes (with ~200ms settle time), layout is applied:

- **Sidebar layout** — Position main app at ratio% left, sidebar apps in right column (overlapped, z-order preserved).
- **Fill-screen layout** — Position all visible apps to full screen (overlapped).

Both use AX `setFrame` calls, which require AX trust. If trust is missing, layout silently fails (logged at `.info`); hide/show still worked, so the space is functional (just without window positioning).

**Code references:**
- Hide/unhide: `AppWindowManager.swift:328-345`
- Layout defer: `AppWindowManager.swift:259-264` (schedules apply at T+200ms)

## Special case: fill-screen multiple-app visibility

In a fill-screen space with multiple apps (e.g., Zen and Safari both in Reference), only the user's last-focused app is *visible*. Others are unhidden but *hidden via AX*:

```swift
if space.layout?.type == .fillScreen {
    let visibleApp = fillScreenLastApp[spaceName] ?? space.apps.first
    for app in space.apps {
        if app == visibleApp {
            setAppHidden(bundleID: app, hidden: false)
        } else {
            setAppHidden(bundleID: app, hidden: true)  // AX hide, not unhide
        }
    }
}
```

This allows cmd-tabbing between apps in the same fill-screen space to hide the previous one and show the new one, without triggering a space switch.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:198-212` — fill-screen activation branch.

## Related docs

- [Space Switching](./space-switching.md) — When and why visibility changes
- [Layout Strategies](./layout-strategies.md) — Positioning after visibility
- [Cross-Space Switching (Delta 9)](./cross-space-switching.md) — CMD+TAB visibility flows
- [macOS Windowing Primitives](./macos-windowing.md) — NSRunningApplication vs AX

## Known issues

**BUG-5:** CMD+TAB to a sidebar-slot app has ~200ms animation lag because we must wait for AX readiness post-unhide before calling `setFrame`. Future work: replace fixed 200ms delay with AX readiness polling.

**Workaround notes:** The current approach (fixed delay) is simpler and matches Hammerspoon's behavior. It feels acceptable in practice for most apps; only high-frequency CMD+TAB mashing feels laggy.

## Implementation checklist (Delta 0+)

- [x] Hide all non-space apps on activation
- [x] Unhide all space apps on activation
- [x] Defer layout apply by ~200ms for AX readiness
- [x] Handle AX inaccessibility on pre-move resize
- [x] Handle AX inaccessibility on activation-time frame
- [ ] Replace 200ms fixed delay with AX readiness polling (future)
- [ ] Multi-display per-display visibility (future)
