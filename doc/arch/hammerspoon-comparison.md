# Hammerspoon POC Comparison

Tilr's behavioural reference is a ~730-line Hammerspoon Lua script (`~/projects/dotfiles/home/hammerspoon/init.lua`). This document maps HS APIs to Tilr equivalents and explains behavioural differences forced by the native rewrite.

## Hammerspoon architecture

Hammerspoon is a macOS automation framework: a Lua runtime (LuaJIT) bundled with bindings to AppKit/AX/CoreGraphics. The `hs.*` modules are high-level Lua facades over low-level macOS primitives. The Hammerspoon process hosts the Lua interpreter running on the Cocoa main-thread run loop; user scripts execute single-threaded relative to that loop.

```
Hammerspoon:
  Lua scripts (user code — init.lua)
      ↓
  hs.* Lua bindings (high-level synchronous-feeling APIs)
      ↓
  macOS C/ObjC (AXUIElement, NSRunningApplication, NSScreen,
                Carbon EventHotKey, CGEventTap, NSPanel, GCD, ...)

Tilr:
  Swift code (TilrApp + CLI)
      ↓
  Direct macOS C/ObjC (same low-level layer, no wrapper)
  — AXUIElementSetAttributeValue / AXObserverCreate
  — NSRunningApplication.hide() / unhide()
  — NSScreen.screens / NSScreen.main
  — Carbon RegisterEventHotKey (via HotKey SPM)
  — NSPanel + SwiftUI (PopupWindow)
  — DispatchQueue.main.asyncAfter
```

**Key insight:** Hammerspoon's wrapper layer absorbs many async/race details. A Lua script calling `win:setFrame(...)` sees synchronous-feeling API even though the underlying AX call is async. The Lua run loop's single-threaded tick means HS never re-enters its own observer during a frame set. Tilr calls low-level APIs directly, surfacing races that HS hid.

## Side-by-side API map

| Capability | Hammerspoon | Tilr | Difference |
|---|---|---|---|
| Running app lookup | `hs.application.get(bundleId)` | `NSRunningApplication.runningApplications(withBundleIdentifier:)` | HS bundles app + windows + bundle ID into one wrapper; Tilr splits into NSRunningApplication (lifecycle) + AX (windows) |
| Enumerate running apps | `hs.application.runningApplications()` | `NSWorkspace.shared.runningApplications` | Direct equivalents; HS wraps each as Lua object |
| Frontmost app | `hs.window.focusedWindow()` | `NSWorkspace.shared.frontmostApplication` | HS queries system-wide AX; Tilr takes higher NSWorkspace path |
| Find app's main window | `app:mainWindow()` | `AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute)` + fallback to enumerate windows | HS wraps in single call; Tilr adds retry and enum fallback (Marq pattern) |
| Hide / unhide | `app:hide()` / `app:unhide()` | `NSRunningApplication.hide()` / `unhide()` | Identical underlying call; HS single-thread hides races, Tilr sees them |
| Activate app | `app:activate()` | `NSRunningApplication.activate(options: [])` | Both reach NSRunningApplication.activate; timing differs due to threading |
| Window position/size (read) | `win:frame()` | `AXUIElementCopyAttributeValue` on kAXPosition + kAXSize | Identical AX calls; HS logs drift, Tilr retries |
| Window position/size (write) | `win:setFrame(frame, 0)` | AX kAXPosition + kAXSize calls | Identical primitives; Tilr added explicit ordering (Size then Position then Size) |
| Verify window sizing | Compute delta post-write, log warn if >2px (`init.lua:219-225`) | `retryUntilWindowMatches` polling loop (10ms–200ms retries) | HS logs and moves on; Tilr retries because Zen fights back |
| Hotkey registration | `hs.hotkey.bind(mods, key, fn)` | `HotKey` library (SPM) | Both wrap Carbon RegisterEventHotKey; HS adds Lua callback scaffolding |
| Deferred timer | `hs.timer.doAfter(delay, fn)` | `DispatchQueue.main.asyncAfter(deadline:)` | Identical GCD primitive; durations (0.2s, 0.5s) copied from HS |
| App launch watcher | `hs.application.watcher.new(fn)` with `.launched` / `.activated` | `NSWorkspace.didActivateApplicationNotification` | HS wraps notifications as Lua callbacks with unified enum; Tilr subscribes directly |
| Sidebar observer | `hs.window.filter.new(false)` for `windowMoved` / `windowDestroyed` | `AXObserverCreate` + `AXObserverAddNotification` + `CFRunLoopAddSource` | HS multiplexes system-wide AX; Tilr does per-app per-window |
| Screen info | `hs.screen.allScreens()`, `hs.screen.primaryScreen()`, `screen:frame()` | `NSScreen.screens`, `NSScreen.main`, `screen.frame` | Direct equivalents; Tilr hardcodes `NSScreen.main` everywhere |
| Alert / HUD | `hs.alert.show(msg, ALERT_STYLE, duration)` | `PopupWindow` (NSPanel + SwiftUI) | HS self-draws overlay with CALayer fade; Tilr uses SwiftUI animations (functionally identical) |
| Config reload | `hs.reload()` — re-execute init.lua whole-program | `ConfigStore.reload()` + @Published subscribers re-wire | HS nuclear (rebuild from scratch); Tilr surgical (observers survive) |
| Session state | `sessionAppOverride`, `sessionScreenOverride` dicts cleared by `hs.reload()` | `pendingMoveInto` one-shot, no persistent dict | HS's nuclear reload made state safe; Tilr needs explicit lifecycle |

## Behavioural differences forced by native rewrite

### 1. AX is racy where HS felt synchronous

**HS behavior:** `hs.window:setFrame` issues one AX call and HS's delta-check logs a warning if it drifts. The Lua script doesn't touch AX again until the next user action, so that's the end of the story.

**Tilr behavior:** An AX observer on the same window may fire concurrently, and apps like Zen fight the first few attempts. Tilr has `retryUntilWindowMatches` polling loop (unique behavior not in HS) that verifies the frame was applied and re-applies if needed.

**Why the difference:** Lua's single-threaded tick doesn't permit the app to respond mid-script. Tilr's main-actor observers fire asynchronously and race with our AX calls.

### 2. Hide/unhide timing is the same, but Tilr's watchers see the echo

**HS behavior:** Also calls `app:hide()` before applying layout (`init.lua:190` → `doAfter(0.2)` at line 197), but the Lua script has no AX readiness concern afterward — it just sets frames 200ms later.

**Tilr behavior:** `AppWindowManager.handleAppActivation` (CMD+TAB to a just-unhidden app) needs an extra 200ms guard because the AX main window isn't accessible immediately post-unhide. This is BUG-5.

**Why the difference:** HS never calls `setFrame` from inside an activation handler (only from space-switch, which goes through normal defer path). Tilr's direct in-handler frame application exposes the race.

### 3. Move-into: pre-resize-before-hide (Tilr) vs session-override-before-unhide (HS)

**HS behavior:** Move path (`moveFocusedAppToSpace`, `init.lua:528–560`) uses `sessionAppOverride[bundleId] = targetSpace` to signal the move, then calls `activateSpace` (which consults the override to unhide the moved app specially). Sidebar-slot apps get their frame from the next `applyLayout` pass.

**Tilr behavior:** Pre-resizes sidebar slots *before* hiding (to avoid AX inaccessibility later). On move, sets `pendingMoveInto` (the override equivalent) and also sets `fillScreenLastApp` for fill-screen spaces before calling `switchToSpace`.

**Why the difference:** HS never hits `setFrame` on a hidden window (frame comes from the next tick's `applyLayout`). Tilr pre-resizes to avoid that problem, replicating HS's session-override pattern with explicit setup. See [Move Window to Space](./move-window-to-space-flow.md) for full details.

### 4. No higher-level `hs.window.filter` equivalent

**HS behavior:** `hs.window.filter` multiplexes `windowMoved`, `windowDestroyed`, app filters, etc. into unified events.

**Tilr behavior:** Rebuilds from scratch per-app per-window via `AXObserverAddNotification`. Any new event type (e.g. window-destroyed to re-apply layout) must be added manually to `SidebarResizeObserver`.

**Why the difference:** Tilr prioritizes minimal dependencies (no high-level frameworks). The cost is more boilerplate in `SidebarResizeObserver`.

### 5. Reload is surgical, not nuclear

**HS behavior:** `hs.reload()` blows up Lua runtime (observers, watchers, timers) and rebuilds from scratch.

**Tilr behavior:** `ConfigStore.reload()` publishes to subscribers who individually decide what to re-wire. HotKeyManager re-registers; other adaptors survive unchanged.

**Why the difference:** Tilr's architectural separation (SpaceService owns state, adaptors subscribe) enables surgical reload without full rebuild. This is cleaner but requires each adaptor to handle config changes independently.

### 6. Neither uses private CGS/Spaces APIs

Both HS and Tilr implement "spaces" entirely at the app visibility layer — no Mission Control, no `SLSManagedDisplayGetCurrentSpace`. This is an explicit design choice (see [specifications.md](../kb/specifications.md) §3) and explains why window management is so AX-heavy.

## Implications for current bugs

### BUG-6: Fill-screen move flash

**Root cause:** The fill-screen `OperationType.windowMove` branch ignored `pendingMoveInto` (the move-override flag). Layout computed `visibleApps` without the moved app, causing a brief full-screen flash before hiding.

**Fix:** Set `fillScreenLastApp[targetName] = bundleID` before space switch (replicating HS's `sessionAppOverride` pattern). This ensures the fill-screen branch includes the moved app in `visibleApps`.

**Why HS doesn't have this bug:** HS's move uses the session override mechanism uniformly for both sidebar and fill-screen. Tilr had separate code paths; fill-screen branch was incomplete.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:97-103` — now sets `fillScreenLastApp` before `switchToSpace`.

### BUG-5: CMD+TAB sidebar handoff lag

**Root cause:** HS does not call `setFrame` from inside an activation handler — it only calls `activateSpace`, which goes through the normal 200ms deferred layout path. Tilr's `handleAppActivation` directly resizes the activated sidebar-slot app, which requires its own 200ms AX-readiness delay.

**Options:**
- (a) Make CMD+TAB go through full `activateSpace` path (HS's approach, costs full re-apply)
- (b) Poll for AX readiness instead of fixed 200ms wait

**Current status:** Option (b) is listed as future work. Current 200ms delay matches HS's timing and feels acceptable.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:241-256` — the `wasHidden` branch.

## General intuition for fixing timing bugs

Whenever Tilr hits a timing bug that HS doesn't have, the culprit is usually that **HS leaned on the next tick of the Lua run loop** to smooth over AX races, while **Tilr has explicit observers firing on the same main actor**.

**Fix patterns:**
1. Add a small deferred re-apply (matching HS's `doAfter` pattern).
2. Replicate HS's pre-activation override pattern (like `pendingMoveInto`).
3. Route through the normal space-switch path instead of touching AX directly.
4. Add explicit settle timer and re-entrance guard (like `ignoringResize`).

See [Space Switching](./space-switching.md) and [Window Visibility](./window-visibility.md) for how these patterns are applied.

## Reference: Key HS sections

When investigating Hammerspoon behaviour, refer to:

- **Alert style** (line ~94): Menlo 30pt, `#00ff88` green on `#1a1a2e` navy, fade in 0.1s / hold 1.2s / fade out 0.15s
- **Status overlay** (line ~379): `cmd+alt+space` toggle, shows all spaces + active screen per space
- **Hotkey binding** (line ~505): `bindKey` wrappers, config-driven space keys
- **Move-focused-app** (line ~528): Pre-activate override pattern for cross-space moves
- **Focus watcher** (line ~652): CMD+TAB follow-focus (Delta 9 inspiration)
- **Sidebar drag settle** (line ~278): 500ms ignore-echo timing
- **Layout apply** (line ~197): 200ms defer after hide/unhide

**Working copy:** `/Users/jmdb/projects/dotfiles/home/hammerspoon/init.lua` (symlinked; use this when reading during a session).

## Related docs

- [macOS Windowing Primitives](./macos-windowing.md) — Low-level APIs and gotchas
- [Space Switching](./space-switching.md) — One-code-path invariant
- [Window Visibility](./window-visibility.md) — Hide/unhide timing and defer patterns
- [Sidebar Drag-to-Resize](./sidebar-drag-resize.md) — Re-entrance guard (500ms pattern from HS)
- [Move Window to Space](./move-window-to-space-flow.md) — Apply-and-verify pattern (Zen fighting back)
