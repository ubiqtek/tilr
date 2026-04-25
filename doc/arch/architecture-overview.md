# Tilr Architecture Overview

Tilr is a native macOS workspace manager written in Swift using AppKit and SwiftUI. This document is an index to the architecture documentation; read the focused docs linked below for details on specific subsystems.

## At a glance

Tilr manages named "spaces" (Coding, Reference, Scratch, etc.), each associated with a list of apps. Activating a space hides all other apps, shows the space's apps, and optionally positions their windows via a layout strategy (sidebar or fill-screen). The app is driven by global hotkeys, CLI commands, and workspace activation events.

**Invariants:**
1. User config is read-only to the app. Runtime state lives in a separate file.
2. All space changes funnel through `SpaceService`. One code path, one log line, one event.
3. AX operations race with hide/unhide. Layout timing is carefully sequenced.
4. Sidebar drag-to-resize happens asynchronously with re-entrance guards.

## Core architecture

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

**Design pattern:** Commands flow in through `SpaceService`, which owns state privately and publishes events. Output adaptors subscribe independently, ensuring one event triggers multiple coordinated changes (hide/show, layout, popup, menu bar) without coupling them.

## Key documents

### Foundation

- **[Space Switching](./space-switching.md)** — How space activation works. All space changes funnel through `SpaceService.switchToSpace()`. Covers startup, hotkey press, CLI, and config reload activation sequences.

- **[Window Visibility](./window-visibility.md)** — Hide/unhide timing and AX inaccessibility. Explains why layout is deferred ~200ms post-unhide and how sidebar-move pre-resize works around AX races.

- **[State & Config](./state-and-config.md)** — Two-file model (user config, app state), hot-reload, persistence, activation reasons, and future plans for persistent ratios and per-display state.

### Layout & positioning

- **[Layout Strategies](./layout-strategies.md)** — Sidebar layout (main at ratio%, sidebars in right column) and fill-screen layout (all apps full-screen, overlapped). Covers ratio computation, persistence (session-only for now), AX trust checks, and graceful degradation.

- **[Sidebar Drag-to-Resize](./sidebar-drag-resize.md)** — AX observer lifecycle, re-entrance guard, ratio computation from drag, clamping, and session-only persistence. How the observer is attached/detached on space switch to prevent leaks.

### Advanced

- **[Cross-Space Switching (Delta 9)](./cross-space-switching.md)** — CMD+TAB follow-focus: when the user switches to an app in a different space, automatically activate that space. Covers app-to-space lookup, recursion guard, pre-registration for fill-screen apps, and logging.

- **[macOS Windowing Primitives](./macos-windowing.md)** — Reference for NSRunningApplication, NSWindow, NSWorkspace, NSScreen, and the Accessibility Framework. Known gotchas (AX is fire-and-forget, hidden apps are inaccessible, observer races, permission model) and how Tilr works around them.

### Reference docs (external)

- **[Move Window to Space Flow](./move-window-to-space-flow.md)** (existing) — Deep dive on the apply-and-verify pattern for moving apps between spaces, why Zen fights AX calls, and the specific AX call ordering that works around its window management.

- **[Logging](./logging.md)** (existing) — Logger categories, log levels, and search patterns for debugging.

- **[Hammerspoon POC Comparison](./app-architecture.md#hammerspoon-poc-api-comparison)** (in old app-architecture.md) — Side-by-side API map of HS vs Tilr, behavioural differences forced by native rewrite, and implications for current bugs. (Will be moved to a separate doc in future refactoring.)

## Component responsibilities

| Component | Responsibility | Key files |
|---|---|---|
| **SpaceService** | Domain logic. Commands in (switchToSpace, moveCurrentApp, applyConfig), events out (onSpaceActivated, onNotification). Owns StateStore privately. @MainActor. | `Sources/Tilr/SpaceService.swift` |
| **AppWindowManager** | Hide/show apps per space. Dispatches to layout strategies. Owns long-lived SidebarLayout instance (observer state survives space switches). Handles CMD+TAB cross-space and in-space sidebar framing. | `Sources/Tilr/AppWindowManager.swift` |
| **SidebarLayout** | Position main app at ratio% left, sidebar apps in right column. Owns SidebarResizeObserver. Reads session ratio overrides and config defaults. | `Sources/Tilr/SidebarLayout.swift` |
| **FillScreenLayout** | Position all visible space apps to full screen (overlap). Stateless struct. | `Sources/Tilr/FillScreenLayout.swift` |
| **SidebarResizeObserver** | Own AX observer lifecycle for current sidebar space. Store session ratio overrides. Re-entrance guard. | `Sources/Tilr/SidebarResizeObserver.swift` |
| **UserNotifier** | Show popup on space activation (policy: config.popups.whenSwitchingSpaces). Own PopupWindow. | `Sources/Tilr/UserNotifier.swift` |
| **MenuBarController** | Update menu bar title to "[SpaceName]" or "Tilr". | `Sources/Tilr/MenuBarController.swift` |
| **HotKeyManager** | Register Carbon hotkeys from config. On press, call SpaceService.switchToSpace or AppWindowManager.moveCurrentApp. Re-register on config reload. | `Sources/Tilr/HotKeyManager.swift` |
| **CommandHandler** | Socket / CLI command dispatch. Routes to SpaceService or ConfigStore. | `Sources/Tilr/CommandHandler.swift` |
| **ConfigStore** | Single source of truth for TilrConfig. @Published current. Hot-reload on demand. | `Sources/Tilr/ConfigStore.swift` |
| **StateStore** | In-memory + state.toml persistence. Active space. Owned privately by SpaceService. | `Sources/Tilr/StateStore.swift` |
| **PopupWindow** | Dumb view. No subscriptions, no config, no logging. Fade in → hold → fade out. | `Sources/Tilr/PopupWindow.swift` |

## User actions & sequences

### 1. Space switch (hotkey or CLI)

User presses `cmd+opt+1` → HotKeyManager → `SpaceService.switchToSpace("Coding")` → `onSpaceActivated` event → AppWindowManager hides/shows/layouts, UserNotifier pops, MenuBarController updates.

See [Space Switching](./space-switching.md) for detailed sequence diagram.

### 2. Move app to space (hotkey: opt+shift+<key>)

User holds Zen (Reference, fill-screen) and presses `opt+shift+1` → AppWindowManager sets `fillScreenLastApp` and calls `switchToSpace("Coding")` → layout applies with moved app visible → retryUntilWindowMatches polls for correct sizing → popup fires.

See [Move Window to Space Flow](./move-window-to-space-flow.md) for full details on apply-and-verify.

### 3. Drag-to-resize sidebar

User drags Ghostty's right edge → AXResizedNotification → SidebarResizeObserver callback → read new width → compute ratio → set `ignoringResize = true` → call `setFrame` on sidebar → schedule clear at T+500ms.

See [Sidebar Drag-to-Resize](./sidebar-drag-resize.md) for details on re-entrance guard.

### 4. CMD+TAB within space (sidebar)

User CMD+TABs to Marq (sidebar-slot app) → `handleAppActivation` receives notification → sidebar branch: compute targetFrame → call `setFrame` → hide previous sidebar-slot app.

See [Window Visibility](./window-visibility.md) for AX readiness timing.

### 5. CMD+TAB across spaces (Delta 9)

User CMD+TABs to Zen (different space) → `handleAppActivation` receives notification → cross-space branch: lookup Zen's space (Reference) → set `fillScreenLastApp[Reference] = Zen` → set `isTilrActivating` guard → call `SpaceService.switchToSpace("Reference")` → return early so in-space branch doesn't run → `handleSpaceActivated` re-processes with Zen as focus.

See [Cross-Space Switching (Delta 9)](./cross-space-switching.md) for implementation details.

## Testing & verification

All major user actions have corresponding log messages:

```
verify: /opt/homebrew/bin/just logs-capture | grep -E 'follow-focus:|switching to|moved|space'
```

See [Logging](./logging.md) for all logger categories and search patterns.

## Design decisions

### No native Spaces / Mission Control integration

Tilr does not use macOS Spaces (`SLSManagedDisplayGetCurrentSpace`) or private CGS APIs (unlike yabai). "Spaces" are pure app groupings managed via hide/unhide + layout. This is identical to the Hammerspoon POC and keeps the system simple.

### Hide/unhide for visibility, AX for positioning

macOS provides no public `moveAppToSpace(app, space)` API. Tilr's workaround: hide all non-space apps, unhide space apps, then use AX to position them. Private API alternatives (CGS, hs.spaces) are more fragile; Tilr chooses stability.

### Careful timing for AX races

AX is fire-and-forget and window-inaccessible-when-hidden. This forces careful sequencing: defer layout apply ~200ms post-unhide for AX readiness, pre-resize sidebar apps before hiding, add 200ms delay on activation-time framing. These are not bugs; they're adaptations to real AX semantics that Hammerspoon's Lua wrapper hid.

### Surgical config reload

Hammerspoon's reload is nuclear (tears down Lua runtime). Tilr's is surgical (@Published, observers survive). This is cleaner but requires individual adaptors to handle change (mostly via immutable subscriptions and re-reading on use).

### Session-only ratio persistence (for now)

Sidebar ratios are remembered during the session but not persisted to disk. Delta 9 will fix this by writing to `state.toml`. For now, users can drag to adjust each session; ratios reset on app restart (acceptable because drag frequency is low).

## Future work

- **Delta 9:** Persistent sidebar ratios, per-display active space, fill-screen focus history.
- **Delta 10+:** Multi-display support (per-display spaces and layouts), follow-focus on target display.
- **Long-term:** App-launch watcher (re-apply layout when space apps launch), advanced layout types (grid, cascade).

## Related documents

- **[KB: Specifications](../kb/specifications.md)** — Product and engineering spec; read before changing architecture.
- **[Plan: Starter App (Delta 0–7)](../kb/starter-app-plan.md)** — Build plan for current development cycle.
- **[ADR: Architecture Decision Records](../adr/)** — Specific design choices and trade-offs.

## Getting started with the codebase

1. Read [Space Switching](./space-switching.md) to understand the one-code-path invariant.
2. Read [Window Visibility](./window-visibility.md) to understand hide/unhide timing.
3. Read [State & Config](./state-and-config.md) to understand persistence and hot-reload.
4. Skim [Layout Strategies](./layout-strategies.md) and [Sidebar Drag-to-Resize](./sidebar-drag-resize.md) for positioning and observers.
5. For Delta 9 work, read [Cross-Space Switching (Delta 9)](./cross-space-switching.md) and [macOS Windowing Primitives](./macos-windowing.md).
6. For bug investigation, search logs using patterns from [Logging](./logging.md) and compare against [Hammerspoon POC Comparison](./app-architecture.md#hammerspoon-poc-api-comparison).
