# macOS Windowing Primitives

Overview of the low-level macOS APIs Tilr uses: NSRunningApplication, NSWindow, NSScreen, and the Accessibility Framework.

## NSRunningApplication

Represents a running app process. Available methods:

- **`bundleIdentifier`** — unique reverse-domain bundle ID (e.g., `"com.apple.Safari"`)
- **`hide()` / `unhide()`** — control app visibility across the active space
- **`activate(options:)`** — bring app to foreground (focus + show)
- **`windows`** — list of visible windows (may lag on first access post-unhide; use AX for authoritative reads)

**Why Tilr uses it:** NSRunningApplication is the only public API for hide/unhide, which is critical to the space-switching model.

**Limitations:** No direct window geometry API. Window positioning requires the Accessibility Framework.

## NSWindow

Represents a window in the OS. Accessible via:

- `NSRunningApplication.windows` (filtered by `NSWindow.windowScene`)
- `NSWorkspace.shared.frontmostApplication?.windows`
- AXUIElement queries (more reliable)

**Why Tilr doesn't use it directly for positioning:** NSWindow in Swift UI is harder to access from background processes. AX is the workaround.

## NSScreen

Represents a physical or virtual display. Available properties:

- **`frame`** — full screen frame in screen coordinates
- **`visibleFrame`** — frame excluding dock and menu bar
- **`uuid`** — persistent identifier for the display

**Current usage:** Tilr hardcodes `NSScreen.main` everywhere. Multi-display support deferred to Delta 10+.

**Why:** Single-display assumption keeps code simpler. When multi-display lands, space switching will become per-display, and layout will consider each display's independent frame.

## NSWorkspace

Provides app and display lifecycle notifications:

- **`didActivateApplicationNotification`** — Fires when the frontmost app changes (CMD+TAB, Dock click, programmatic activate).
- **`didLaunchApplicationNotification`** — Fires when an app launches.
- **`runningApplications`** — List of all running apps.
- **`frontmostApplication`** — Currently focused app.

**Tilr uses:**
- `didActivateApplicationNotification` — for cross-space CMD+TAB (Delta 9)
- `runningApplications` — to compute union of all configured apps
- `frontmostApplication` — to identify the active app in move operations

## Accessibility Framework (AXUIElement)

The only public API for reading and writing window geometry. Core operations:

### Read window frame

```swift
var position = CGPoint.zero
var size = CGSize.zero
AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &position)
AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &size)
let frame = CGRect(origin: position, size: size)
```

### Write window frame

```swift
let position = CGPoint(x: x, y: y)
let size = CGSize(width: w, height: h)
AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, position as AnyObject)
AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, size as AnyObject)
```

**Note:** Call Size then Position (order matters for some apps like Zen Browser).

### Find an app's main window

```swift
var mainWindow: AnyObject?
AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindow)
if let axWindow = mainWindow as? AXUIElement {
    // Use this window
} else {
    // Fall back to enumerating all windows (for apps like Marq that don't expose main)
    var windows: AnyObject?
    AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows)
    let windowList = windows as? [AXUIElement] ?? []
}
```

### Observe window resize

```swift
var observer: AXObserver?
AXObserverCreate(pid, callback, &observer)
AXObserverAddNotification(observer, windowElement, kAXResizedNotification as CFString, nil)
CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
```

**Return value:** If `kAXErrorSuccess`, observer is active. If `kAXErrorCannotComplete`, the window is inaccessible (likely hidden).

### Check AX trust

```swift
let isTrusted = AXIsProcessTrusted()
```

If false, all AX operations fail silently. User must grant "Accessibility" permission in System Settings > Privacy & Security.

## Known gotchas

### 1. AX is fire-and-forget

`AXUIElementSetAttributeValue` returns immediately, but the window doesn't actually move synchronously. The app processes the AX call and updates its frame asynchronously. If you immediately read the frame, you get the old value.

**Workaround:** Tilr's `retryUntilWindowMatches` polls the window width every 10–200ms (variable schedule) and re-applies layout if it drifts. Some apps (Zen Browser) fight AX calls for 500–1000ms.

### 2. AX reads fail on hidden windows

When an app is hidden (via `NSRunningApplication.hide()`), its main AX window becomes inaccessible. Dialogs remain accessible, but main windows are gone.

**Workaround:** Pre-resize sidebar-slot apps *before* hiding them, so they're already positioned when unhidden later. For activation-time framing, add a 200ms delay post-unhide before calling `setFrame`.

### 3. AX observer races

When you call `AXUIElementSetAttributeValue` and the observer fires concurrently on the same main thread, the app may ignore the frame or respond slowly. No deadlock (GCD/Swift concurrency), but timing is tricky.

**Workaround:** Re-entrance guard (`ignoringResize` flag) to swallow echo events from our own `setFrame` calls.

### 4. Permission model

User must grant "Accessibility" permission in System Settings. Without it, AX calls fail silently:

```swift
if !AXIsProcessTrusted() {
    // All AX operations will fail silently
    // Hide/show still works, layout just skips frame positioning
    Logger.layout.info("AX not trusted, skipping layout")
    return
}
```

Tilr checks this at layout apply time and degrades gracefully (hide/show still works).

### 5. Some apps don't expose main windows

Apps like Marq don't set `kAXMainWindowAttribute`. Tilr's `AXWindowFinder` falls back to:
1. Enumerate all windows via `kAXWindowsAttribute`.
2. Filter by `kAXStandardWindowSubrole == kAXStandardWindowSubrole`.
3. Return the first match or log `.info` if none found (space still functional, just no positioning).

## Hammerspoon comparison

Hammerspoon's `hs.window:setFrame(frame)` wraps the same AX calls but hides timing complexity behind a synchronous-feeling Lua API. The Lua runtime's single-threaded tick means concurrent observer events can't interrupt the script. Tilr calls low-level AX directly on `@MainActor`, surfacing races that Hammerspoon hid.

This is why Tilr needs:
- Explicit defer (T+200ms) for layout after unhide
- Explicit retry loop for window sizing (Zen fights back)
- Explicit re-entrance guard for observer callbacks
- Explicit 200ms AX readiness delay on activation-time framing

The workarounds are neither bugs nor missing features — they're the cost of handling races that exist at the AX level but are invisible in Lua's abstraction.

## Related docs

- [Window Visibility](./window-visibility.md) — Hide/unhide timing
- [Layout Strategies](./layout-strategies.md) — AX `setFrame` calls
- [Sidebar Drag-to-Resize](./sidebar-drag-resize.md) — AX observer lifecycle
- [Cross-Space Switching (Delta 9)](./cross-space-switching.md) — NSWorkspace notifications

## Implementation checklist

- [x] NSRunningApplication hide/unhide
- [x] NSRunningApplication activate
- [x] NSWorkspace.frontmostApplication
- [x] AX window frame reads
- [x] AX window frame writes (Position then Size then Position)
- [x] AX window find (main window with fallback)
- [x] AX observer for resize notifications
- [x] AX trust check at apply time
- [x] Retry loop for window sizing (Zen fighting)
- [x] Re-entrance guard for observer callbacks
- [x] 200ms AX readiness delay post-unhide
- [ ] Multi-display NSScreen iteration (Delta 10+)
- [ ] Per-display window positioning (Delta 10+)
