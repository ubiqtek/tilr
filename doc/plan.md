# Tilr — Delta Progress

Working tracker for the starter app build plan in
[`kb/starter-app-plan.md`](kb/starter-app-plan.md). Update this as each delta
lands — check boxes, add a dated note, link the commit/PR.

**Status legend:** ⬜ not started · 🟡 in progress · ✅ done · ⏭️ skipped

---

## Snapshot

| Delta | Title | Status | Landed |
|---|---|---|---|
| 0–5b | Core infrastructure | ✅ | 2026-04-18 |
| 6 | App visibility | ✅ | 2026-04-19 |
| 7 | App layout | ✅ | 2026-04-20 |
| 8 | Moving apps to a space | ⬜ | — |
| 9 | State file | ⬜ | — |
| 10 | Polish | ⬜ | — |
| 11 | Follow focus on CMD-TAB | ⬜ | — |

**Current focus:** Delta 8 — Moving apps to a space

---

## Prerequisites

- [ ] Homebrew tap transferred `jimbarritt/homebrew-tap` → `ubiqtek` org
- [x] New repo `github.com/ubiqtek/tilr` created
- [ ] Ubiqtek Developer ID cert available on this machine

---

## Delta 0 — Skeleton

**Goal:** app runs, shows in menu bar, quits cleanly.

- [x] Xcode App project created, `LSUIElement=true`
- [x] SPM deps added: HotKey, TOMLKit
- [x] `NSStatusItem` with static title "Tilr"
- [x] Quit menu item wired up
- [x] App icon in asset catalogue

**Notes:**

---

## Delta 1 — Popup alert

**Goal:** popup triggerable from menu, positioned on focused screen.

- [x] Borderless `NSPanel` (nonactivating, transparent bg)
- [x] SwiftUI centre-label view (Menlo 30pt, #00ff88 on #1a1a2e, matching Lua style)
- [x] Fade in → hold → fade out
- [x] Help menu item shows keyboard shortcuts for 3s

**Notes:**

---

## Delta 2 — Hotkey → popup

**Goal:** global hotkey working, popup responds.

- [x] `cmd+opt+space` registered via HotKey
- [x] Press fires popup

**Notes:**

---

## Delta 3 — CLI scaffolding + health

**Goal:** `tilr` CLI binary exists, can query app health via Unix-domain
socket, and can stream logs. No config dependency — stands alone for
debugging.

### Target layout

- App target renamed `Tilr` → `TilrApp`, `PRODUCT_NAME=Tilr` → `Tilr.app`
- New target `TilrCLI`, `PRODUCT_NAME=tilr` → `tilr` binary
- New shared sources dir `Sources/Shared/` compiled into both targets

### Protocol

- Unix-domain socket at `~/Library/Application Support/tilr/tilr.sock`
- Newline-delimited JSON request/response
- First commands:
  - `status` → `{ok, pid, uptimeSeconds, spacesCount, activeSpace}`

### CLI commands (via Swift ArgumentParser)

- `tilr status`
  - App running → prints health table, exit 0
  - App not running (ECONNREFUSED / ENOENT) → prints
    `Tilr.app is not running.\n\n  Start with: open -a Tilr.app`, exit 1
- `tilr logs`
  - Wraps `/usr/bin/log stream --predicate 'subsystem == "io.ubiqtek.tilr"' --style compact`
  - No IPC — works whether app is running or not
- `tilr logs --last 100` (nice-to-have, via `log show`)

### Deliverables

- [x] Rename app target in `project.yml`; add CLI target
- [x] Add `swift-argument-parser` SPM dependency to CLI target
- [x] `Sources/Shared/Protocol.swift` — `TilrRequest`, `TilrResponse`, `StatusData` Codable types
- [x] `Sources/Tilr/SocketServer.swift` — POSIX Unix-domain socket listener, dispatches to `CommandHandler`
- [x] `Sources/Tilr/CommandHandler.swift` — handles `status`
- [x] `AppDelegate` wires up `SocketServer.start()` in `applicationDidFinishLaunching`, `unlink` on `applicationWillTerminate` + SIGINT/SIGTERM handlers
- [x] `Sources/TilrCLI/TilrCLI.swift` — ArgumentParser root + `Status` + `Logs` subcommands
- [x] `Sources/TilrCLI/SocketClient.swift` — connect, send, read response
- [x] `justfile`: `build-cli`, `install-cli` recipes; existing recipes still target `Tilr.app`
- [x] Acceptance: `tilr status` works with app running and without; `tilr logs` streams live output

**Notes:** The CLI entry point must not use `@main` in a file named `main.swift` (Swift treats that file as top-level entry automatically). Renamed to `TilrCLI.swift`.

---

## Delta 4 — Config (YAML, domain model, CLI commands)

**Goal:** config parsed from YAML, domain model established, CLI commands to inspect and manipulate config.

### Format

- Replace `TOMLKit` with `Yams` SPM package
- Config file: `~/.config/tilr/config.yaml`
- Missing file → write default (empty spaces, default shortcuts) and continue

### Default config written on first launch

```yaml
keyboardShortcuts:
  switchToSpace: cmd+opt
  moveAppToSpace: cmd+shift+opt

spaces: {}
```

### Domain model — `Sources/Shared/Config.swift`

```swift
struct TilrConfig: Codable {
    var keyboardShortcuts: KeyboardShortcuts
    var spaces: [String: SpaceDefinition]   // key = display name
}
struct KeyboardShortcuts: Codable {
    var switchToSpace: String               // e.g. "cmd+opt"
    var moveAppToSpace: String              // e.g. "cmd+shift+opt"
}
struct SpaceDefinition: Codable {
    var id: String                          // single char 0-9 or a-z
    var apps: [String]                      // bundle IDs
    var layout: Layout?
}
struct Layout: Codable {
    var type: LayoutType
    var main: String?                       // bundle ID of main pane app
    var ratio: Double?                      // main pane width 0.0–1.0
}
enum LayoutType: String, Codable { case sidebar }
```

Full hotkey derived at runtime: `switchToSpace` + space `id` → e.g. `cmd+opt+1`

### Example config (Hammerspoon-equivalent spaces)

```yaml
keyboardShortcuts:
  switchToSpace: cmd+opt
  moveAppToSpace: cmd+shift+opt

spaces:
  Coding:
    id: "1"
    apps:
      - com.github.wez.wezterm
      - com.google.Chrome
    layout:
      type: sidebar
      main: com.github.wez.wezterm
      ratio: 0.65
  Reference:
    id: "2"
    apps:
      - com.apple.Safari
  Scratch:
    id: "3"
    apps:
      - com.apple.Notes
```

### Tests first — `TilrCoreTests` target

- Parse above YAML string → assert 3 spaces, IDs, apps, shortcuts, layout fields
- Derived hotkey: `Coding` space → `cmd+opt+1`
- Missing `layout` → `nil` on Reference/Scratch
- Default config round-trips cleanly (write → parse → write → identical)
- Malformed YAML → throws

### App side

- [x] Swap `TOMLKit` → `Yams` in `project.yml`
- [x] `Sources/Shared/Config.swift` — domain model types above
- [x] `Sources/Tilr/ConfigLoader.swift` — `load()` reads `~/.config/tilr/config.yaml`; missing file → write default and return it; malformed → log error, return nil
- [x] `AppDelegate` loads config on launch, logs space count
- [x] `tilr status` reports real `Spaces` count (socket `StatusData.spacesCount`)

### CLI commands

- [x] **`tilr config`** — print raw YAML + path header:
  ```
  Config: ~/.config/tilr/config.yaml

  keyboardShortcuts: ...
  ```
- [x] **`tilr config help`** — agent-readable schema with inline comments explaining each field
- [x] **`tilr spaces add <name> <id> [bundle-ids...]`** — append space; error if ID already taken
- [x] **`tilr spaces set-layout <name-or-id> --type sidebar [--main <bundle-id>] [--ratio <float>]`**
  - Single char → resolve by ID; anything longer → resolve by name

**Notes:** `TilrCoreTests` target needs `GENERATE_INFOPLIST_FILE: YES` — unit test bundles require an Info.plist. `SocketServer.commandHandler` made internal (not private) so `AppDelegate` can push the loaded config into it post-startup. `tilr status` shows `Spaces: 0` until app restarts after CLI edits — expected, no hot-reload until Delta 8.

---

## Delta 5 — Hotkeys from config + menu bar title + popup config

**Goal:** config-driven hotkeys; active space shown in menu bar; popup visibility controlled by config.

### Part A — `PopupConfig` in `TilrConfig`

Add to `Sources/Shared/Config.swift`:

```swift
public struct PopupConfig: Codable {
    public var whenSwitchingSpaces: Bool
    public var whenMovingApps: Bool
    public static let `default` = PopupConfig(whenSwitchingSpaces: true, whenMovingApps: true)
    public init(whenSwitchingSpaces: Bool = true, whenMovingApps: Bool = true) {
        self.whenSwitchingSpaces = whenSwitchingSpaces
        self.whenMovingApps = whenMovingApps
    }
}
```

Add `var popups: PopupConfig` to `TilrConfig` (default `.default`).

Default config written on first launch must include the `popups` block:

```yaml
keyboardShortcuts:
  switchToSpace: cmd+opt
  moveAppToSpace: cmd+shift+opt

popups:
  whenSwitchingSpaces: true
  whenMovingApps: true

spaces: {}
```

### Part B — In-memory `StateStore`

New file `Sources/Tilr/StateStore.swift`:

```swift
import Combine
import Foundation

final class StateStore: ObservableObject {
    @Published private(set) var activeSpace: String? = nil   // display name

    func setActiveSpace(_ name: String?) {
        DispatchQueue.main.async { self.activeSpace = name }
    }
}
```

No persistence yet (Delta 6 adds the state file).

### Part C — `HotKeyManager` reads config

Replace hardcoded `cmd+opt+space` with config-driven registration:

- Parse `keyboardShortcuts.switchToSpace` modifier string → `NSEvent.ModifierFlags`
  - Mapping: `"cmd"` → `.command`, `"opt"` → `.option`, `"shift"` → `.shift`, `"ctrl"` → `.control`
- For each space: parse `space.id` single char → `Key` (digits use `.zero`…`.nine`; letters use `.a`…`.z`)
- Build `KeyCombo(key:modifiers:)` and register `HotKey`
- On press:
  1. `stateStore.setActiveSpace(spaceName)`
  2. If `config.popups.whenSwitchingSpaces`: `popup.show(spaceName)`
  3. Log the fire event
- Invalid / unparseable hotkey → log warning, skip (don't crash)
- Remove the old hardcoded `cmd+opt+space` handler

`HotKeyManager.init` gains a `config: TilrConfig` and `stateStore: StateStore` parameter.

Helper `func parseModifiers(_ string: String) -> NSEvent.ModifierFlags` and
`func parseKey(_ char: String) -> Key?` — keep these `private`.

### Part D — `MenuBarController` observes `StateStore`

- Add a `Combine` `AnyCancellable` to `MenuBarController`
- Subscribe to `stateStore.$activeSpace` on the main queue
- `nil` → title `"Tilr"`; `"Coding"` → title `"[Coding]"`
- `MenuBarController.init` gains a `stateStore: StateStore` parameter

### Part E — Wire up in `AppDelegate`

```swift
private let stateStore = StateStore()
```

Pass `stateStore` to `MenuBarController` and `HotKeyManager`.
Pass `config` to `HotKeyManager`.

### Deliverables checklist

- [ ] `PopupConfig` struct added to `Config.swift`
- [ ] `TilrConfig.popups` field added with default
- [ ] Default config YAML includes `popups` block
- [ ] `StateStore.swift` created
- [ ] `HotKeyManager` parses config, registers per-space hotkeys, checks `popups.whenSwitchingSpaces`
- [ ] `MenuBarController` subscribes to `StateStore.$activeSpace`, updates title
- [ ] `AppDelegate` creates `StateStore`, passes to both managers
- [ ] `just build` clean
- [ ] Unit test: `parseModifiers("cmd+opt")` → `[.command, .option]`; `parseKey("1")` → `.one`

**Notes:**

---

## Delta 5b — Display configuration

**Goal:** display config section in YAML; `tilr displays list` / `configure`; on-launch jump to default space.

### Domain model — `Sources/Shared/Config.swift`

```swift
public struct DisplayConfig: Codable {
    public var name: String?         // user-chosen label e.g. "Main"
    public var defaultSpace: String? // space name or space id (resolved at runtime)
    public init(name: String? = nil, defaultSpace: String? = nil) { ... }
}
```

Add `var displays: [String: DisplayConfig]` to `TilrConfig` — key is the Tilr display ID as a string ("1", "2", …).

Update `TilrConfig.init(from:)` (already custom) to use `decodeIfPresent` for `displays`, defaulting to `[:]`.

Example YAML:
```yaml
displays:
  "1":
    name: Main
    defaultSpace: Coding
```

### CLI — `Sources/TilrCLI/TilrCLI.swift`

Add a `Displays` group (registered in the root `Tilr` command alongside `Spaces`).

**`tilr displays list`**

Table with columns: `ID | Tilr Name | System Name | Default Space`

- Enumerate `NSScreen.screens`; Tilr assigns IDs 1-N by index order
- For each screen: show system `localizedName`, user-configured `name` (or `—`), configured `defaultSpace` (or `—`)
- For now only one display is expected; show all screens anyway

Example output:
```
ID  Tilr Name   System Name              Default Space
1   Main        Built-in Retina Display  Coding
```

**`tilr displays configure <id> <name> <default-space>`**

- `<id>` — integer, Tilr display ID
- `<name>` — user label string (can be quoted, allow spaces)
- `<default-space>` — space name or space id; validate it exists in config.spaces
- Load config, set `config.displays["\(id)"] = DisplayConfig(name: name, defaultSpace: resolvedSpaceName)`, save
- Print confirmation

Update `config help` to include a `displays` section.
Update `tilr context` commands list to include `tilr displays list` and `tilr displays configure <id> <name> <default-space>`.

### On-launch behaviour — `Sources/Tilr/AppDelegate.swift`

After `ConfigLoader.load()` and `StateStore` are wired up, resolve and activate the default space for display 1:

```swift
if let defaultSpaceRef = loadedConfig.displays["1"]?.defaultSpace {
    let resolved = resolveSpace(ref: defaultSpaceRef, in: loadedConfig)
    if let name = resolved {
        stateStore.setActiveSpace(name)
        if loadedConfig.popups.whenSwitchingSpaces {
            popup.show(name)
        }
    }
}
```

`resolveSpace(ref:in:)` — private helper: if `ref.count == 1`, resolve by space id; else resolve by name. Returns `String?`.

`popup` must be created before this block.

### Deliverables checklist

- [ ] `DisplayConfig` struct in `Config.swift`
- [ ] `displays: [String: DisplayConfig]` in `TilrConfig`; `init(from:)` uses `decodeIfPresent`
- [ ] `Displays` command group in `TilrCLI.swift` with `list` and `configure` subcommands
- [ ] Root `Tilr` command registers `Displays.self`
- [ ] `tilr displays list` shows correct table
- [ ] `tilr displays configure` validates space, saves config
- [ ] `config help` updated with displays section
- [ ] `tilr context` commands updated
- [ ] On-launch default space activation in `AppDelegate`
- [ ] `just build` clean

---

## Delta 6 — App visibility (AppWindowManager)

**Goal:** Activating a space hides apps not in that space and shows the apps that are. This makes Tilr actually functional — it's the first delta where a space switch has substantive behaviour beyond a popup.

**Out of scope:** Window positioning / layout (sidebar, fill-screen). That's a later delta. No app launching — if a configured app isn't running, skip it gracefully. No multi-display awareness — an app goes wherever macOS puts it.

**Architecture:** `AppWindowManager` is an output adaptor per `doc/arch/app-architecture.md`. It subscribes to `SpaceService.onSpaceActivated`, reads the `Space` definition from `ConfigStore`, and calls `NSRunningApplication` APIs to hide/show apps. It knows nothing about the popup, menu bar, or hotkey layers.

**Subtasks:**
- Create `Sources/Tilr/AppWindowManager.swift` — `@MainActor`, constructor takes `ConfigStore` and subscribes to `SpaceService.onSpaceActivated`.
- On activation event:
  - Look up the target `Space` in `ConfigStore.current.spaces` by name.
  - Compute the union of bundle IDs across ALL configured spaces (`allSpaceApps`).
  - Compute this space's app bundle IDs (`thisSpaceApps`).
  - For each `NSRunningApplication`: if its bundle ID is in `allSpaceApps` but NOT in `thisSpaceApps`, call `hide()`. If it's in `thisSpaceApps`, call `unhide()` (and optionally activate the `layout.main` app if present).
  - Apps whose bundle IDs aren't in any configured space are left alone.
- Add `Logger.windows` category. Log a single line per activation: `"applying space 'Coding': showing [...], hiding [...]"` (use `privacy: .public`).
- Wire into `AppDelegate` alongside `UserNotifier` and `MenuBarController`.

**Verification:**
- Launch Ghostty, Marq, Zen Browser, Chrome.
- `cmd+opt+1` (Coding): Ghostty + Marq visible; Zen + Chrome hidden.
- `cmd+opt+2` (Reference): Zen + Chrome + Safari visible; Ghostty + Marq hidden.
- Non-configured apps (e.g. Finder, whatever else is open) are untouched.
- `just logs` shows the `Logger.windows` activation line.

**Risk / notes:**
- Hiding/unhiding may require Accessibility permission — verify the app is in System Settings → Privacy → Accessibility. If not, document the prompt.
- Handle apps that aren't currently running — don't crash, just log and skip.

---

## Delta 7 — App layout

**Goal:** Per-space window positioning using sidebar and fill-screen layout modes, via the Accessibility API.

### Architecture

Control flow lives in `AppWindowManager` but delegates to small layout classes to keep the manager tidy:
- `Sources/Tilr/Layouts/SidebarLayout.swift`
- `Sources/Tilr/Layouts/FillScreenLayout.swift`
- Common protocol `LayoutStrategy` (avoid clash with `Config.Layout`) with one method: `func apply(space: SpaceDefinition, config: TilrConfig, screen: NSScreen) throws`
- `AppWindowManager.handleSpaceActivated` calls `hide/unhide` (existing Delta 6 behaviour), then picks the right strategy based on `space.layout?.type` and invokes it.

Accessibility API (`AXUIElement`) is used to position other apps' windows — `NSWindow` only controls your own app. This is a new permission requirement.

### First-run AX permission flow

- On app launch, call `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt: true`. This auto-triggers the system prompt (and opens System Settings → Privacy → Accessibility) if not already trusted.
- If permission is later denied at runtime, layout application fails gracefully — log a warning via `Logger.windows` and skip the positioning step. Hide/show (Delta 6) keeps working regardless.
- Don't block app startup on the prompt; it's asynchronous.

### Layout behaviours

**Sidebar:** `main` app takes `ratio` of the screen width (default 0.65 if unset) on the left. All other visible space apps stack in the remaining right column (same frame — they overlap). Preserves z-order — setting AX position/size attributes doesn't reorder windows. Verify empirically.

**Fill-screen:** every visible space app is sized to the full screen frame (apps overlap/stack). Z-order preserved as above.

**Screen selection:** `NSScreen.main` for MVP. Multi-display screen assignment via the `displays` config map is a future refinement.

### Dynamic resize (sidebar only)

When the user drags the edge of the main window or a sidebar window in a `sidebar`-layout space, the other windows re-tile to match. The new ratio is stored in a **session-only** in-memory dict (`[spaceName: Double]`) — not written to disk. Persistence across app restarts is a Delta 9 concern (state file).

**Mechanism:**
- Use the Accessibility API observer APIs (`AXObserverCreate`, `AXObserverAddNotification` with `kAXResizedNotification`).
- A new helper class `SidebarResizeObserver` (in `Sources/Tilr/Layouts/SidebarResizeObserver.swift`) owns:
  - The set of per-app `AXObserver` handles for the currently observed space.
  - The session ratio override dict `[String: Double]`.
  - A re-entrance flag to ignore observer callbacks that fire as a result of our own `setFrame` calls.
- `SidebarLayout` is promoted from `struct` to `final class` (it needs identity to own the observer instance). `FillScreenLayout` stays a `struct`.
- `AppWindowManager` holds a single long-lived `SidebarLayout` instance (instead of constructing a new one per dispatch) so its observer state survives across space switches.

**Lifecycle:**
- On `SidebarLayout.apply(...)`: the layout (a) tears down any existing observer set, (b) positions windows as today — reading the session override dict first, falling back to `config.layout.ratio`, falling back to `0.65`, (c) sets up fresh observers for the now-visible main + sidebar apps in this space.
- On space switch to a non-sidebar layout: observers are torn down (they shouldn't fire, but clean up to avoid leaks).

**Resize callback behaviour:**
- If the `ignoringResize` flag is true (set by our own `setFrame` — see below), return immediately.
- Identify which window fired: main, or one of the sidebars.
- If main was dragged: new ratio = `main.width / screen.width`. Clamp to `[0.1, 0.9]`. Store in session dict under `spaceName`. Re-tile the sidebar windows to the remaining right column.
- If a sidebar was dragged (user grabs the sidebar's left edge): new ratio = `sidebar.x / screen.width`. Clamp to `[0.1, 0.9]`. Store in session dict. Re-tile the main window and any other sidebar windows.
- Set `ignoringResize = true` immediately before the re-tile `setFrame` calls. Clear it ~500ms later on the main queue (`DispatchQueue.main.asyncAfter`) to swallow the echo events the OS generates from our own resize.

**Threading:**
- `AXObserver` callbacks fire on the main run loop. Everything stays `@MainActor`.
- The C callback bridges to Swift via `Unmanaged.passUnretained(self).toOpaque()` in the refcon, the standard AX pattern.

### Edge cases

- App not running → log and skip, don't crash.
- App running but no main window yet (just launched) → log and skip. No retry in this delta.
- `layout.main` set but not in `space.apps` → log and skip for cleanliness.
- No apps visible in the space → no-op, log nothing.
- Sidebar with zero non-main apps → main fills screen. With zero main but non-main visible → all non-main apps fill screen.

### Timing and implementation notes

- Start with zero delay after `unhide()`. If testing reveals a race, add a small dispatch delay; document the value and the reason.
- AX is finicky: `AXUIElementSetAttributeValue` can silently fail on sandboxed apps, full-screen apps, or apps that haven't granted their own AX cooperation. Log errors explicitly.
- `NSScreen.main` is the screen containing the focused window — may not match the `displays` config; this is fine for MVP and documented as a limitation.
- The config's `Layout.ratio` is a `Double?`; default 0.65 when nil. Fill-screen ignores ratio.
- Z-order preservation is an assumption, not a guarantee — call it out in Verification for empirical check.

### Out of scope (defer to later deltas/polish)

- Multi-display assignment.
- App-launch watcher that re-applies layout when a space app launches late.
- Stage Manager / Mission Control interactions.

**Subtasks:**
- [ ] AX permission check on launch via `AXIsProcessTrustedWithOptions` (in `AppDelegate` or a new helper). Log whether trusted.
- [ ] `Sources/Tilr/Layouts/LayoutStrategy.swift` — protocol (or whatever naming avoids clashing with `Config.Layout`).
- [ ] `Sources/Tilr/Layouts/SidebarLayout.swift` — implements sidebar positioning via AX.
- [ ] `Sources/Tilr/Layouts/FillScreenLayout.swift` — implements fill-screen positioning via AX.
- [ ] `AppWindowManager.handleSpaceActivated` — after hide/show, dispatch to the right strategy.
- [ ] Each layout strategy emits `Logger.windows.info("applying layout '<type>'")` at the start of `apply()`, before any positioning work, so logs have a clear header separating hide/show from layout application.
- [ ] Helper for AX window lookup: get the main/focused window of a running app and set frame via `kAXPositionAttribute` + `kAXSizeAttribute` (`CGPoint` and `CGSize` wrapped in `AXValue`).
- [ ] Graceful failures logged via `Logger.windows`.
- [ ] `project.yml` — add `Layouts/` dir to the Tilr target sources if xcodegen doesn't auto-include it (verify).
- [ ] Run `just gen` after adding files (reminder in the plan).
- [ ] `Sources/Tilr/Layouts/SidebarResizeObserver.swift` — owns per-app `AXObserver` set, session ratio override dict, re-entrance flag.
- [ ] Promote `SidebarLayout` from `struct` to `final class`; hold single long-lived instance in `AppWindowManager`.
- [ ] `SidebarLayout.apply` reads session ratio override (keyed by space name) before falling back to `config.layout.ratio` or `0.65`.
- [ ] Tear-down + re-setup of observers on each `apply`, scoped to the active space's visible apps.
- [ ] Re-entrance guard: `ignoringResize` flag set around our own `setFrame` calls, cleared ~500ms later.
- [ ] Clamp ratio to `[0.1, 0.9]`.

**Verification:**
1. Launch Ghostty + Marq, hit `cmd+opt+1` (Coding / sidebar layout): Ghostty left ~65% of screen, Marq right ~35%, both at full screen height.
2. Launch Zen Browser, hit `cmd+opt+2` (Reference / fill-screen layout): Zen fills full screen.
3. Switch back to `cmd+opt+1`: Ghostty/Marq re-tile (should not drift).
4. AX permission denied: switching spaces still hides/shows correctly; log shows a warning about missing AX trust; no crash.
5. `just logs` shows layout application line, e.g. `applied sidebar layout: main=Ghostty, ratio=0.65, sidebars=[Marq]`.
6. Windows retain their z-order after repositioning (foreground window stays foreground).
7. Drag the right edge of Ghostty (main) left: Marq (sidebar) resizes in real-time to maintain right-column fill; ratio persists while the app runs.
8. Drag the left edge of Marq (sidebar) right: Ghostty (main) resizes to match; other sidebars re-tile.
9. Drag main all the way right past the 0.9 clamp: resize stops at 90% — sidebar stays ≥10% wide.
10. Drag main all the way left past the 0.1 clamp: resize stops at 10%.
11. Switch to Reference (fill-screen) and back to Coding: the previously dragged ratio is preserved within the session.
12. Restart the app: ratio resets to config default (session-only — state-file persistence is Delta 9).

**Risk / notes:**
- AX is finicky: `AXUIElementSetAttributeValue` can silently fail on sandboxed apps, full-screen apps, or apps that haven't granted their own AX cooperation. Log errors explicitly.
- `NSScreen.main` is the screen containing the focused window — may not match the `displays` config; this is fine for MVP and documented as a limitation.
- The config's `Layout.ratio` is a `Double?`; default 0.65 when nil. Fill-screen ignores ratio.
- Z-order preservation is an assumption, not a guarantee — call it out in Verification for empirical check.
- `AXObserver` C callback must be bridged via refcon (`Unmanaged.passUnretained(self).toOpaque()`). Holding a strong reference to the observer on the Swift side is essential — dropping it silently stops the callbacks.
- 500ms re-entrance window is empirical (matches Lua). Tune if false-positive re-entrance bleeds in.
- Observer leaks are possible if teardown is skipped — always tear down before setting up, and on space-type change (sidebar → fill-screen).

---

## Delta 8 — Moving apps to a space

**Goal:** Hotkey (opt+shift+id) moves the currently focused app from its current space into the target space, at runtime. In-memory only — no config write.

**Subtasks:**
- [ ] Bind `moveAppToSpace` modifier + space id hotkeys (mirrors switch hotkeys)
- [ ] On trigger: identify frontmost app's bundle ID
- [ ] Remove bundle ID from its current space's `apps` list (in-memory)
- [ ] Add bundle ID to the target space's `apps` list (in-memory)
- [ ] Log the move; no config save

**Verification:**
- [ ] Focused app moves to target space when opt+shift+id pressed
- [ ] App is hidden/shown correctly on next space switch
- [ ] Original space no longer manages the moved app

**Notes:**

---

## Delta 11 — Follow focus on CMD-TAB

**Goal:** when the user CMD-TABs (or otherwise activates) an app that lives
in a different space than the currently active one, automatically switch to
that app's space so the rest of its space's apps come with it.

- [ ] Register an `NSWorkspace.didActivateApplicationNotification` observer
- [ ] On activation: look up the app's bundle ID in `config.spaces`,
      find the space that contains it, call `SpaceService.activate(name:)`
- [ ] Guard against recursion: while we're activating a space, ignore
      activation events triggered by our own `app.activate()` call (matches
      Hammerspoon's `activatingSpace` re-entrancy flag with a ~0.5s window)
- [ ] Skip when the app belongs to the current active space (no-op)
- [ ] Skip when the app belongs to no configured space

**Reference:** Hammerspoon `focusWatcher` in
`~/projects/dotfiles/home/hammerspoon/init.lua` (~line 652).

---

## Delta 9 — State file

**Goal:** state survives restart; active space restored on launch.

- [ ] `StateStore` with Combine publisher for `activeSpace`
- [ ] Loads/saves `~/Library/Application Support/tilr/state.toml`
- [ ] Hotkey fire → `StateStore.setActive(name)` persists & publishes
- [ ] Never writes to user `config.toml`
- [ ] `tilr status` reports `activeSpace`; new CLI command `tilr switch <name>`

**Notes:**

---

## Delta 10 — Polish

**Goal:** shippable starter.

- [x] `tilr spaces config add-app/remove-app` — edit space apps list in config file
- [ ] Config file watch → hot reload on save
- [ ] Launch at login via `SMAppService`
- [ ] App icon finalised
- [ ] About dialog polished

**Notes:**

---

## Decision log

Record any plan deviations here with a date and one-line reason. Link to an
ADR in `doc/adr/` if the change is architectural.
