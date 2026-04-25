# App Architecture (Streamlined Index)

**See [Architecture Overview](./architecture-overview.md) for the complete guide.**

This document has been refactored into focused sub-documents for clarity. Use this page as an index to find what you need.

## Quick navigation

### For understanding how space switching works
- **[Space Switching](./space-switching.md)** — How activation works, the one-code-path invariant, startup/hotkey/CLI sequences, and generation tokens for guarding deferred work

### For understanding visibility and timing
- **[Window Visibility](./window-visibility.md)** — Hide/unhide timing, AX inaccessibility, and why we defer layout apply
- **[Async & Races](./async-and-races.md)** — Patterns for reliable deferred work (generation tokens, guard suppression, Combine gotchas). **Read this before touching async code.**

### For understanding positioning
- **[Layout Strategies](./layout-strategies.md)** — Sidebar layout (main + sidebars), fill-screen layout, ratio computation, and AX graceful degradation
- **[Sidebar Drag-to-Resize](./sidebar-drag-resize.md)** — Drag observers, re-entrance guards, and ratio persistence

### For Delta 9 work
- **[Cross-Space Switching (Delta 9)](./cross-space-switching.md)** — CMD+TAB follow-focus: app-to-space lookup, recursion guards, pre-registration for fill-screen

### For state and configuration
- **[State & Config](./state-and-config.md)** — Two-file model, hot-reload, persistence, and future plans for persistent ratios

### For low-level primitives
- **[macOS Windowing Primitives](./macos-windowing.md)** — NSRunningApplication, NSWorkspace, AX Framework, known gotchas, and workarounds
- **[Hammerspoon Comparison](./hammerspoon-comparison.md)** — HS vs Tilr API map, behavioural differences, and fix patterns for timing bugs

## Overview (high-level)

See [macOS Windowing Primitives](./macos-windowing.md) for context on why we use the Accessibility Framework.

**Core architecture:**

```
INPUT ADAPTERS (translate user actions → domain commands)
┌──────────────────┐                    ┌──────────────────┐
│  HotKeyManager   │                    │ CommandHandler   │
│  (Carbon events) │                    │  (socket / CLI)  │
└──────────────────┘                    └──────────────────┘
        │                                        │
        └────────────────┬─────────────────────┘
                         ▼
              Commands: switchToSpace,
              moveCurrentApp, applyConfig
                         │
┌─────────────────────────────────────────────────────────────────┐
│                      DOMAIN (SpaceService)                       │
│  Commands in → Events out. Owns state privately (via StateStore). │
│  No UI or window API knowledge.                                   │
└──────────────────────┬──────────────────────────────────────────┘
                       │
        ┌──────────────┴──────────────┐
        │ Events: onSpaceActivated,   │
        │ onNotification              │
        ▼                             ▼
   OUTPUT ADAPTERS (each does one job, subscribes to events)
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│ AppWindowManager │  │  UserNotifier    │  │ MenuBarController│
│ (hide/show/      │  │  (popup window)  │  │ (menu bar title) │
│  layout)         │  │                  │  │                  │
└──────────────────┘  └──────────────────┘  └──────────────────┘
```

**Key invariants (for detailed explanations, see linked docs):**

1. **User config is read-only.** See [State & Config](./state-and-config.md).
2. **All space changes funnel through `SpaceService`.** See [Space Switching](./space-switching.md).
3. **AX operations race with hide/unhide.** See [Window Visibility](./window-visibility.md).
4. **Sidebar drag-to-resize is asynchronous.** See [Sidebar Drag-to-Resize](./sidebar-drag-resize.md).

## User Actions & Sequences (summaries)

### Space switch (hotkey or CLI)

**Summary:** User presses `cmd+opt+1` → HotKeyManager calls `SpaceService.switchToSpace("Coding")` → Service updates state and publishes `onSpaceActivated` event → AppWindowManager hides/shows apps and applies layout → UserNotifier shows popup → MenuBarController updates title.

**For detailed sequence, timing decisions, generation tokens, and edge cases, see [Space Switching](./space-switching.md).**

**Key timing:**
- T=0: Hotkey → space switch command
- T=0: Service updates state and broadcasts event (sync)
- T=100ms: Layout apply (after hide/unhide settle for AX readiness; may need 200ms for slow apps)
- T=350ms: Popup shows (after layout, so windows are positioned first)

---

### Move app to space (hotkey: opt+shift+<key>)

**Summary:** User holds Zen (Reference, fill-screen) and presses `opt+shift+1` → AppWindowManager sets `pendingMoveInto` / `fillScreenLastApp` → calls `switchToSpace("Coding")` → `handleSpaceActivated` sees the move hint and includes Zen in visible apps → layout applies with Zen positioned → retry loop verifies sizing.

**For detailed sequence, pre-resize rationale, and AX inaccessibility workarounds, see [Move Window to Space](./move-window-to-space-flow.md).**

**Key timing:**
- T=0: Move command → set move hint before space switch
- T=200ms: Layout apply (after hide/unhide)
- T=300ms–980ms: Retry loop verifies window sizing

---

### Apply layout (on space switch, resize on drag)

**Summary:** After space switch or drag settle, compute layout (sidebar or fill-screen), check AX trust, position windows, and set up observers (sidebar only). Gracefully degrade if AX not trusted.

**For detailed ratio computation, persistence, observer lifecycle, and Zen retry pattern, see:**
- [Layout Strategies](./layout-strategies.md) — Positioning and AX trust
- [Sidebar Drag-to-Resize](./sidebar-drag-resize.md) — Observer attachment and re-entrance guard
- [Move Window to Space](./move-window-to-space-flow.md) — Retry loop for fighting apps

---

### Drag-to-resize sidebar (AX observer callback → layout reapply)

**Summary:** User drags Ghostty's right edge → AX fires `kAXResizedNotification` → observer callback reads new width → computes ratio → sets `ignoringResize = true` → repositions sidebar → clears flag at T+500ms.

**For detailed re-entrance guard mechanics, ratio computation, and persistence, see [Sidebar Drag-to-Resize](./sidebar-drag-resize.md).**

**Key invariant:** `ignoringResize` flag is set *before* `setFrame` call and cleared after 500ms to suppress echo events from our own positioning.

---

### Hide/unhide apps on space switch

**Summary:** Compute which apps are in the target space → unhide them → hide all others → schedule layout apply at T+200ms (to let AX become accessible post-unhide).

**For detailed timing, AX inaccessibility workarounds, and pre-resize rationale, see [Window Visibility](./window-visibility.md).**

**Key timing:** T+200ms defer waits for AX readiness post-unhide. Additional 200ms guard on activation-time framing (CMD+TAB) handles AX inaccessibility when focusing a just-unhidden app.

---

## Components (quick reference)

See [Architecture Overview](./architecture-overview.md#component-responsibilities) for the full component table.

**Key components:**
- **SpaceService** — Domain logic. Commands in, events out. Owns state privately.
- **AppWindowManager** — Hide/show apps, apply layout, handle CMD+TAB cross-space and in-space.
- **SidebarLayout** / **FillScreenLayout** — Position windows per strategy.
- **SidebarResizeObserver** — AX observer for drag-to-resize and re-entrance guard.
- **UserNotifier**, **MenuBarController** — Output adaptors (subscribe to events).
- **HotKeyManager**, **CommandHandler** — Input adapters (translate user actions to commands).
- **ConfigStore**, **StateStore** — Configuration and runtime state persistence.

## Hammerspoon POC: API comparison

**See [Hammerspoon Comparison](./hammerspoon-comparison.md) for full details.**

The behavioural reference is a ~730-line HS Lua script (`~/projects/dotfiles/home/hammerspoon/init.lua`). Key differences from Tilr:

### Hammerspoon architecture (summary)

Hammerspoon is a macOS automation framework. At its core it is a Lua runtime (LuaJIT) bundled with a large set of Lua bindings to macOS C/ObjC APIs. The `hs.*` modules are high-level Lua facades over low-level macOS primitives — `hs.window` wraps `AXUIElement`, `hs.application` wraps `NSRunningApplication` (plus some AX), `hs.hotkey.bind` wraps Carbon `RegisterEventHotKey` (same as our `HotKey` SPM library), `hs.screen` wraps `NSScreen`, `hs.alert` is a self-drawn `NSPanel` overlay (functionally identical to Tilr's `PopupWindow`), `hs.timer.doAfter` wraps `DispatchQueue.main.asyncAfter`, and `hs.window.filter` is a high-level multiplexed facade over raw `AXObserver` notifications. The Hammerspoon process hosts a Lua interpreter that runs on a Cocoa main-thread run loop; user scripts execute single-threaded relative to that loop.

Tilr is the structural inverse: a native Swift app that calls the same low-level macOS primitives directly, with no Lua wrapper layer.

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

**Implication for timing bugs:** The `hs.*` wrapper layer absorbs many async/race details — a Lua script calling `win:setFrame(...)` sees a synchronous-feeling API even though the underlying AX call is asynchronous. The Lua run loop's single-threaded tick means HS never re-enters its own observer during a frame set. Tilr calls the low-level APIs directly on `@MainActor`, and its `AXObserver` callbacks fire on the same thread. Any race that HS hid behind its wrappers is fully visible in Tilr — which is the root cause of BUG-5 and BUG-6. The fix pattern is almost always to replicate what the HS wrapper did implicitly: defer re-entry, route through the normal space-switch path, or add an explicit settle timer.

### Key API differences (summary)

See [Hammerspoon Comparison](./hammerspoon-comparison.md#side-by-side-api-map) for full API mapping.

- **HS has high-level wrappers** (e.g. `hs.window:setFrame`) that hide async details. Tilr calls low-level APIs directly.
- **HS is single-threaded** (Lua run loop tick). Tilr has explicit observers firing asynchronously.
- **Observer races** are invisible in HS (one tick per user action) but visible in Tilr (concurrent callbacks).
- **Retry loops** (e.g. `retryUntilWindowMatches`) are unique to Tilr because apps fight AX calls. HS just logs and moves on.
- **Surgical config reload** (Tilr) vs nuclear reload (HS). Observers survive Tilr reloads; they're destroyed in HS.

### Behavioural differences forced by native rewrite (summary)

See [Hammerspoon Comparison](./hammerspoon-comparison.md#behavioural-differences-forced-by-native-rewrite) for details on all 6 key differences and how they affect timing and observer logic.

**TL;DR:** HS's single-threaded Lua run loop hides AX races; Tilr's explicit observers surface them. Fix patterns: add deferred re-apply, pre-register moves (like `pendingMoveInto`), or route through normal space-switch path.

### Bug implications

See [Hammerspoon Comparison](./hammerspoon-comparison.md#implications-for-current-bugs) for analysis of BUG-5 (CMD+TAB lag) and BUG-6 (fill-screen move flash).

## State & config

**See [State & Config](./state-and-config.md) for full details.**

**Two-file model:**
- **`~/.config/tilr/config.toml`** (user-owned, read-only to app) — spaces, apps, layout, hotkeys, popup policy.
- **`~/Library/Application Support/tilr/state.toml`** (app-owned) — active space, session ratios (future: persistent ratios per-display).

**Key invariants:**
- Config is read-only; app never writes to it.
- State is app-owned; user should not edit it.
- State is persisted on every space switch (async, non-blocking).
- ConfigStore.current is @Published; subscribers react to reload.

## Fixes & optimizations

### BUG-6 fix: Fill-screen move flash (2026-04-25)

**Problem:** Moving Marq to Reference (fill-screen space) briefly flashed the app full-screen then hid all windows.

**Root cause:** The fill-screen `OperationType.windowMove` branch ignored `pendingMoveInto`, the move-override flag set before space switch. This caused `handleSpaceActivated` to compute `visibleApps = [moved]` (only the moved app), hide all competitors, but then the fill-screen layout didn't include the moved app in its final positioning because it wasn't being tracked. The app briefly rendered at full screen before being hidden by competitor-hide logic.

**Fix:** Set `fillScreenLastApp[targetName] = bundleID` before calling `switchToSpace` (equivalent to HS's `sessionAppOverride` pattern). This ensures the fill-screen branch's `handleSpaceActivated` path includes the moved app in `visibleApps` computation. Also wired `retryUntilWindowMatches` in the fill-screen path to verify window sizing post-layout.

**Related fix:** Hotkey re-registration guard — was subscribing to all config changes, now only on hotkey/space name/ID changes. Reduces spurious re-registrations and avoids lost hotkeys during unrelated config reloads.

---

### FillScreenLayout optimization: Only frame visible apps (2026-04-25)

**Problem:** Layout applied AX frames to all running apps in a space, including hidden ones, generating unnecessary AX calls and risking frames on inaccessible windows.

**Solution:** Filter `space.apps` to only visible apps before positioning: `.contains { !$0.isHidden }`. Reduces AX call volume and avoids framing hidden apps (which are inaccessible post-hide and would fail silently anyway).

**Code location:** `FillScreenLayout.swift`, `.spaceSwitch` case — pre-filter to `visibleApps` before calling `setWindowFrame`.

---

### retryUntilWindowMatches aggressive tuning (2026-04-25)

**Initial problem:** Windows were resizing slowly or not at all when apps like Zen Browser internally fought AX calls for 500–1000ms. The initial fixed-delay approach (300ms check, up to 4 retries) caught the problem but felt sluggish.

**Tuning experiment:** Tested aggressive early checks with variable retry intervals to catch fast-settling apps immediately while still covering slow apps.

**Final schedule:** 10ms initial check, then retries at [20ms, 50ms, 100ms, 200ms, 200ms, 200ms, 200ms].

| Attempt | Delay | Cumulative | Notes |
|---------|-------|------------|-------|
| 1 (initial) | 10ms | 10ms | Fast apps caught almost immediately |
| 2 | 20ms | 30ms | |
| 3 | 50ms | 80ms | Most apps settled by here |
| 4 | 100ms | 180ms | Covers medium-speed apps |
| 5–8 (retries) | 200ms each | ~980ms | Covers Zen's 500–1000ms window settle time |

**Total budget:** ~980ms, still under Zen's typical window settling time of ~360ms + safety buffer.

**Results:** Windows resize "almost instant" without flakiness; early 10ms–100ms attempts catch fast-settling apps immediately, while later 200ms retries handle Zen's fighting behaviour. No observed failures; feels snappiest at 10ms vs earlier 300ms threshold.

**Threshold history:** Started at 300ms → 100ms → 50ms → 20ms → 10ms. Empirical testing confirmed 10ms is optimal for responsiveness without introducing races.

---

## Known issues & open questions

**Recent fixes (2026-04-25):**

- **Generation tokens** — Added `activationGeneration` counter to guard against rapid hotkey presses leaving windows mis-positioned. See [Space Switching](./space-switching.md) and [Async & Races](./async-and-races.md).
- **`isTilrActivating` timing** — Fixed by setting guard at START of `handleSpaceActivated` (before hide/show), not inside the deferred activate block. Prevents macOS auto-promotion from triggering recursive cross-space switches. See [Cross-Space Switching (Delta 9)](./cross-space-switching.md).
- **Layout delay tightened** — 200ms → 100ms for snappier response; revert to 200ms if AX failures appear in logs. See [Async & Races](./async-and-races.md#layout-timing-100ms-vs-200ms).
- **Removed Combine `.receive(on:)`** — Was queuing subscribers async even from main, breaking generation token capture order. Critical lesson: never re-add it. See [Async & Races](./async-and-races.md#pattern-3-receiveon-is-not-free--the-critical-combine-gotcha).

**Remaining investigation (non-blocking):**

- **BUG-5:** CMD+TAB sidebar handoff has ~200ms lag (AX readiness delay). See [Window Visibility](./window-visibility.md).

**Future work:**

- **Multi-display:** Currently hardcoded to `NSScreen.main`. Per-display spaces planned for Delta 10+.
- **Persistent sidebar ratios:** Session-only in Delta 0–8. Delta 9 will persist to `state.toml`.
- **App-launch watcher:** Not yet implemented. Apps inherit layout when unhidden, so not critical.

See [State & Config](./state-and-config.md#future-plans-delta-9) for more future plans.

## Event channels & Logger

**SpaceService publishes:**

- **`onSpaceActivated(name, reason)`** — Real space is active. Subscribers: AppWindowManager, UserNotifier, MenuBarController.
- **`onNotification(message)`** — Transient message (e.g. "↺ Config"). Only UserNotifier reacts.

**Activation reasons:** `.hotkey`, `.cli`, `.configReload`, `.startup` — control popup visibility policy.

See [State & Config](./state-and-config.md#activation-reasons) for reason details and [Logging](./logging.md) for all logger categories and usage.

---

## Appendices

### Reference: Move-window-to-space design

See [Move Window to Space](./move-window-to-space-flow.md) for the apply-and-verify pattern, why Zen fights AX, and the specific AX call ordering.

**Key points:**
- Hide competitors *before* resize (avoid flashing)
- Pre-resize sidebar slots *before* hiding (avoid AX inaccessibility later)
- Retry loop verifies width matches (Zen fights for 500–1000ms)

### Reference: macOS Windowing and Accessibility APIs

See [macOS Windowing Primitives](./macos-windowing.md) for detailed explanations of:
- NSWindow, NSRunningApplication, NSWorkspace, NSScreen
- AXUIElement, attributes, notifications, observers
- Why Tilr uses AX (no public `moveAppToSpace` API)
- Known gotchas: async reads, inaccessibility when hidden, observer races, non-standard windows, permission model
- Private API alternatives (CGS, yabai) and trade-offs
