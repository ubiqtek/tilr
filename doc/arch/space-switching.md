# Space Switching

How Tilr activates a named space and coordinates hide/show/layout changes.

## Overview

Space switching is the core operation. When a user presses a hotkey (e.g. `cmd+opt+1`), runs a CLI command (`tilr switch Coding`), or the app starts up, we activate a space. This operation:

1. Updates the active space in `StateStore` and persists to `state.toml`
2. Logs the activation event (one line per event, for observability)
3. Fires the `onSpaceActivated` event to all subscribers
4. Triggers hide/show and layout application in `AppWindowManager`

## Architecture

All space changes funnel through `SpaceService.switchToSpace(_ name: reason:)` — one code path, one log line, one event. This is a critical invariant: whether triggered by hotkey, CLI, or startup, the sequence is identical.

**Flow diagram:**

```
INPUT (hotkey/CLI/startup)
         ↓
SpaceService.switchToSpace(name, reason)
         ↓
[Sync] Update activeSpace, persist state.toml, log
         ↓
Publish onSpaceActivated event (broadcast)
         ↓
Subscribers react (AppWindowManager, UserNotifier, MenuBarController)
         ↓
[Async] Layout applies, popup shows, menu bar updates
```

**Code references:**
- `SpaceService.switchToSpace()` — `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/SpaceService.swift:36`
- `AppWindowManager.handleSpaceActivated()` — `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:259`

## Sequence: hotkey-triggered space switch

**Scenario:** User presses `cmd+opt+1` to switch to "Coding" space (sidebar layout with Ghostty main, Marq sidebar).

**Steps:**

1. **T=0:** HotKeyManager captures the hotkey event, calls `SpaceService.switchToSpace("Coding", reason:.hotkey)`.

2. **Sync path:** Service updates `activeSpace = "Coding"`, persists `state.toml` (async write, doesn't block), publishes `onSpaceActivated` event.

3. **AppWindowManager receives event:**
   - Looks up `ConfigStore.current.spaces["Coding"]` → `{apps: [Ghostty, Marq], layout: .sidebar}`
   - Computes all bundle IDs across all spaces (to determine hide candidates)
   - Hides every app not in Coding via `NSRunningApplication.hide()`
   - Unhides Coding's apps via `NSRunningApplication.unhide()`
   - Schedules layout apply at T+200ms (giving macOS time to make unhidden apps' AX windows accessible)
   - Applies `SidebarLayout`: positions Ghostty at 65% left, Marq at 35% right
   - Attaches AX resize observer to both apps

4. **UserNotifier receives event:**
   - Checks `config.popups.whenSwitchingSpaces`
   - If true, shows popup at T+350ms (after layout has applied, so windows are positioned before user sees the alert)

5. **MenuBarController receives event:**
   - Updates menu bar title to `"[Coding]"`

**Why this timing matters:**
- Hide/unhide is asynchronous on the OS side, so we defer layout apply by ~200ms to wait for AX readiness.
- Popup is even more deferred (T+350ms) so the user sees the space's windows already laid out before the notification appears.
- If AX is not trusted, layout apply silently fails at apply time (logged at `.info` level); hide/show still worked, so the space is functional.

## State & persistence

- **Active space** is stored in `StateStore` and persisted to `~/Library/Application Support/tilr/state.toml`.
- **User config** (`~/.config/tilr/config.toml`) is read-only to the app; space names, apps per space, and layout types live there.
- On app launch, the previous active space is restored from `state.toml`.
- On each space switch, the new active space is persisted immediately (async disk write).

## Generation tokens & stale work suppression

**Problem:** Layout is deferred ~100ms after visibility changes to let AX become accessible. But if the user rapidly presses hotkeys (e.g. `cmd+opt+1`, `cmd+opt+2`), the first space's queued layout might apply after we've already switched to the second space, leaving the second space's windows mis-positioned.

**Solution:** Use a generation counter to mark each space activation.

```swift
// In AppWindowManager
private var activationGeneration: UInt64 = 0

private func handleSpaceActivated(name: String) {
    activationGeneration &+= 1
    let gen = activationGeneration
    
    // ... hide/show logic ...
    
    // Defer layout apply; capture generation NOW, not inside the block
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self, self.activationGeneration == gen else {
            Logger.windows.info("space activation \(gen) stale (now \(self?.activationGeneration ?? 0)) — dropping queued layout for '\(name)'")
            return
        }
        // ... apply layout ...
    }
}
```

**Pattern:**
1. Increment `activationGeneration` at the top of `handleSpaceActivated`
2. Capture the new value: `let gen = activationGeneration`
3. Before any async work fires, guard: `guard self.activationGeneration == gen else { ... }`
4. If stale, log and return; drop the queued work

This ensures:
- Rapid hotkey presses only lay out the most recent space
- Stale layout doesn't overwrite the current space's positioning
- The log line makes it visible in debugging: "space activation 5 stale (now 7)"

**Code reference:** `AppWindowManager.swift:268–283` (handleSpaceActivated), `AppWindowManager.swift:380–384` (layout defer with gen check).

**Related:** [Async & Races](./async-and-races.md) — full explanation of why this pattern is needed and how to apply it in other contexts.

## Edge cases

### Multi-display (future)

Currently, only `NSScreen.main` is used. Config has a `displays` section with per-display default space, but app logic doesn't use it yet. When implemented, `activeSpace` will become per-display, and space lookups will be scoped to the active screen.

### No configured default space

If the user hasn't set a default space at launch, `SpaceService.applyConfig()` logs a warning and fires `onNotification` (not `onSpaceActivated`). This is a user-visible "↺ Config" message with no state change.

### Config reload

When the user runs `tilr reload-config`, the old default space may no longer exist. `applyConfig` is called again with `reason: .configReload`, which re-validates the default space and activates it if valid.

## Related docs

- [Window Visibility](./window-visibility.md) — How hide/unhide affects AX accessibility
- [Layout Strategies](./layout-strategies.md) — Sidebar and fill-screen positioning
- [Cross-Space Switching (Delta 9)](./cross-space-switching.md) — CMD+TAB follow-focus
- [State & Config](./state-and-config.md) — Persistence model

## Implementation checklist (Delta 0+)

- [x] One code path: `SpaceService.switchToSpace`
- [x] Persist active space to `state.toml`
- [x] Broadcast `onSpaceActivated` event
- [x] Hide/show apps per space
- [x] Apply layout strategy
- [x] Show popup on space switch
- [x] Update menu bar title
