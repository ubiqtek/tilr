# Sidebar Drag-to-Resize

How the AX observer detects sidebar-edge drags and recomputes the main/sidebar ratio in real time.

## Overview

When a user drags the right edge of the main app in a sidebar layout, `SidebarResizeObserver` captures the drag via an AX observer, recomputes the sidebar ratio, and repositions the sidebar apps. The observer is attached after every layout apply and torn down on space switch.

## Observer lifecycle

**Attach (on space switch):**

```swift
// T=200ms after space activation (after hide/unhide and layout apply)
SidebarLayout.apply(spaceName: "Coding", ...)
  → SidebarResizeObserver.attach(mainBundleID: "Ghostty", sidebarBundleIDs: ["Marq"])
```

The observer subscribes to `kAXResizedNotification` for all apps in the space.

**Detach (on next space switch):**

When `AppWindowManager` receives `onSpaceActivated` for a new space, the old observer's subscriptions are torn down:

```swift
SidebarResizeObserver.detachAll()
```

This prevents leaks (no accumulation of observers across space switches) and ensures drags only affect the current space's apps.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/SidebarResizeObserver.swift:attach()`, `detachAll()`.

## Drag sequence

**User action:** Drag the right edge of main app (Ghostty) from 65% to 50% of screen width.

**Timeline:**

```
T=0:    User begins drag
        → macOS generates kAXResizedNotification
        
T=?:    Observer callback fires (mainWindow resized)
        
        1. Check ignoringResize flag
           - false (not currently suppressing echoes) → proceed
           - true (waiting for echo events) → return early
        
        2. Read new main window frame via AX
           - newWidth = 50% of screen
        
        3. Compute new ratio
           - newRatio = newWidth / screenWidth = 0.50
           - Clamp to [0.1, 0.9] ✓
           - Store in sessionRatio["Coding"] = 0.50
        
        4. Suppress echo events
           - Set ignoringResize = true
           - Call setFrame on sidebar (right 50%)
           - Schedule ignoringResize = false at T+500ms
        
T+?:    Observer fires again (our setFrame echoed back)
        - ignoringResize flag is true → return early
        - Frame is not re-applied
        
T+500ms: Schedule clears ignoringResize flag
         - Future drags will be processed normally
        
T=end:  User releases mouse
```

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/SidebarResizeObserver.swift:handleResize()`.

## Re-entrance guard

AX observers fire on *any* resize, including our own `setFrame` calls. Without a guard, dragging would trigger:
1. User drag → observer fires → we call `setFrame`
2. Our `setFrame` → observer fires again → we call `setFrame` again
3. Loop indefinitely (or until the app stops updating)

**Solution:** Set `ignoringResize = true` before calling `setFrame`, then clear it after 500ms:

```swift
ignoringResize = true
AXWindowHelper.setWindowFrame(sidebarApp, newFrame)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    self.ignoringResize = false
}
```

The 500ms window is tuned empirically to match Hammerspoon's behavior. It's long enough to swallow all echo events from our own calls, but short enough that interactive drag-and-release feels snappy.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/SidebarResizeObserver.swift:285-297`.

## Ratio computation

When the main app resizes, we compute the new ratio:

```swift
let newRatio = newMainWindowWidth / screenWidth
```

When a sidebar app resizes (user dragged its internal window), we compute from its x-position:

```swift
let sidebarX = sidebarApp.frame.x
let newRatio = sidebarX / screenWidth
```

Both require AX reads to get the current window frames. The observer callback is triggered synchronously (on the main thread), so AX reads should complete quickly.

## Clamping

Ratios are clamped to [0.1, 0.9] to prevent pathological layouts:

```swift
newRatio = max(0.1, min(0.9, newRatio))
```

- **Minimum 0.1** — Prevents sidebar from being too narrow (hard to interact with).
- **Maximum 0.9** — Prevents main app from being too narrow.

## Persistence: session-only (Delta 0–8)

Ratios are stored in a memory dict:

```swift
sessionRatio: [String: Double] = [:]  // spaceName → ratio
```

This dict is **not** persisted to disk. On app restart, ratios reset to config defaults. This is acceptable for now because:
- Tiles are rarely dragged by power users (once per session, usually).
- If the user does drag, they can drag again after restart (muscle memory).
- Persisting to `state.toml` is planned for Delta 9.

**Persistent ratios (Delta 9+):** Will be stored in `state.toml` alongside `activeSpace`, so ratios survive app restart. See `state-and-config.md` for details.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/SidebarResizeObserver.swift:52`.

## Related docs

- [Layout Strategies](./layout-strategies.md) — When observers are attached
- [Space Switching](./space-switching.md) — Observer detach on space switch
- [State & Config](./state-and-config.md) — Persistent ratio storage (future)

## Implementation checklist

- [x] Attach observer after layout apply
- [x] Detach observer on space switch (prevent leaks)
- [x] Re-entrance guard (ignoringResize flag)
- [x] Ratio computation from main app width
- [x] Ratio computation from sidebar x-position
- [x] Clamp to [0.1, 0.9]
- [x] Session-only persistence (memory)
- [ ] Persistent storage to `state.toml` (Delta 9)
- [ ] Per-display ratio overrides (Delta 10+)
