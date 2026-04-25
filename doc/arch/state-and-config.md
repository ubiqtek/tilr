# State & Config

Tilr separates user configuration from runtime state using a two-file model: user-owned config (read-only to app) and app-owned state (written by app only).

## Two-file model

### Config: `~/.config/tilr/config.toml` (read-only)

User-owned, edited by text editor or CLI commands.

**Contents:**
- Space definitions: name, app list per space, layout type (sidebar/fill-screen), layout ratio override
- Hotkey bindings: modifiers and keys for space switching and moving apps
- UI policy: when to show popups, menu bar behavior
- Display defaults: per-display default space
- Miscellaneous: log level, socket path

**Read on:**
- App launch (blocking; logs error if malformed)
- Explicit `tilr reload-config` CLI command (async; HotKeyManager re-registers hotkeys on change)

**Accessed via:**
- `ConfigStore.current` — @Published property with subscribers
- Subscribers: HotKeyManager, AppWindowManager, UserNotifier, MenuBarController, SpaceService

**Invariant:** App never writes to this file. CLI commands may mutate it (e.g. `tilr spaces add`), but the app only reads.

### State: `~/Library/Application Support/tilr/state.toml` (app-owned)

App-owned, written by Tilr only. User should not edit this file.

**Contents (current):**
- Active space name

**Contents (Delta 9+):**
- Active space name (per-display, future)
- Session sidebar ratio overrides
- Fill-screen app focus history

**Written on:**
- Space switch: async disk write (non-blocking)
- Drag-to-resize: session dict only (no disk write until Delta 9)

**Restored on:**
- App launch: `StateStore` reads `state.toml` on startup (async, missing file is OK)

**Accessed via:**
- `StateStore` (private to SpaceService) — holds in-memory copy
- SpaceService is the canonical owner; AppWindowManager queries it

**Invariant:** Only the app writes to this file. Mutations are atomic (write to temp file, rename).

## Read/write timing

| Operation | File(s) | Blocking? | Notes |
|---|---|---|---|
| App launch | `config.toml` | blocking | Errors logged, app may degrade |
| App launch | `state.toml` | async | Missing file is OK (no previous state) |
| Hotkey press | config (in memory) | non-blocking | ConfigStore already loaded |
| Space switch | `state.toml` | async | Non-blocking; `DispatchQueue.global()` |
| Drag-to-resize | session dict (memory) | non-blocking | No disk I/O |
| `tilr reload-config` | config + state | async | HotKeyManager re-wires on change |

## Config hot-reload

When the user runs `tilr reload-config` or manually edits `config.toml` (if file-system watch is added), Tilr reloads:

1. **ConfigStore.reload()** reads `config.toml` and re-publishes `@Published current`.
2. **Subscribers react individually:**
   - **HotKeyManager:** Re-registers hotkeys (only if hotkey bindings changed, not on every reload).
   - **AppWindowManager:** Uses new space definitions on next space switch.
   - **UserNotifier:** Uses new popup policy immediately.
   - **MenuBarController:** Updates menu bar title (minimal impact).
3. **SpaceService.applyConfig()** re-validates the default space and activates it if valid (or sends a notification if invalid).

**Why surgical reload?** Unlike Hammerspoon's nuclear reload (tears down Lua runtime, observers, timers), Tilr's reload is surgical. Observers survive, in-flight timers complete normally. This is cleaner but requires individual adaptors to handle config changes — which they do, mostly via immutable subscriptions and re-reading on each use.

## Activation reasons

Every space activation carries a reason for observability and policy:

```swift
enum ActivationReason {
    case hotkey         // User pressed a hotkey
    case cli            // User ran `tilr switch ...`
    case configReload   // `tilr reload-config` or config changed
    case startup        // App launched
}
```

**Policy:** UserNotifier uses reason to decide popup visibility:

| Reason | Popup shown? |
|---|---|
| `.hotkey` | if `config.popups.whenSwitchingSpaces` |
| `.cli` | if `config.popups.whenSwitchingSpaces` |
| `.configReload` | always |
| `.startup` | always |

Hotkey and CLI are user-initiated (hide popup if user wants quiet); configReload and startup are system events (always show to avoid surprise).

## Future plans (Delta 9+)

### Persistent sidebar ratios

Currently, drag-to-resize ratios are session-only (memory dict, cleared on app restart). Delta 9 will persist them to `state.toml`:

```toml
[state]
activeSpace = "Coding"

[state.sidebarRatios]
Coding = 0.60
Reference = 0.65
```

This allows ratios to survive app restart. Implementation: `SidebarResizeObserver` calls `stateStore.updateRatio(spaceName:ratio:)` on every drag settle.

### Per-display active space

Currently, one global `activeSpace`. Multi-display support (Delta 10+) will store per-display:

```toml
[state.displaySpaces]
"1" = "Coding"
"2" = "Reference"
```

Where `"1"` is `NSScreen.main`'s UUID or persistent identifier.

### Fill-screen focus history

Track the last-focused app per fill-screen space to restore focus on space re-activation:

```toml
[state.fillScreenApps]
Reference = "com.apple.Safari"
```

This requires reading `NSRunningApplication.bundleIdentifier` on every in-space cmd-tab and writing to disk on space switch or app deactivation.

## Related docs

- [Space Switching](./space-switching.md) — When state is persisted
- [Layout Strategies](./layout-strategies.md) — Ratio computation and persistence
- [Sidebar Drag-to-Resize](./sidebar-drag-resize.md) — Session dict details

## Implementation checklist (Delta 0+)

- [x] Read config on app launch
- [x] Read state on app launch (optional)
- [x] Write active space to state.toml on switch
- [x] ConfigStore @Published for hot-reload
- [x] HotKeyManager re-registers on config reload
- [x] Activation reasons and logging
- [ ] Persistent sidebar ratios to `state.toml` (Delta 9)
- [ ] Per-display active space (Delta 10)
- [ ] Fill-screen focus history (Delta 9+)
