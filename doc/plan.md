# Tilr — Delta Progress

Working tracker for the starter app build plan in
[`kb/starter-app-plan.md`](kb/starter-app-plan.md). Update this as each delta
lands — check boxes, add a dated note, link the commit/PR.

**Status legend:** ⬜ not started · 🟡 in progress · ✅ done · ⏭️ skipped

---

## Snapshot

| Delta | Title | Status | Landed |
|---|---|---|---|
| 0 | Skeleton | ✅ | 2026-04-17 |
| 1 | Popup alert | ✅ | 2026-04-17 |
| 2 | Hotkey → popup | ✅ | 2026-04-17 |
| 3 | CLI scaffolding + health | ✅ | 2026-04-18 |
| 4 | Config loading | ✅ | 2026-04-18 |
| 5 | Hotkeys from config + menu bar title + popup config | ✅ | 2026-04-18 |
| 5b | Display config + default space | ✅ | 2026-04-18 |
| 6 | App visibility (AppWindowManager) | ⬜ | — |
| 7 | State file | ⬜ | — |
| 8 | Menu bar title | ✅ | 2026-04-18 |
| 9 | Polish | ⬜ | — |

**Current focus:** Delta 6 — App visibility (AppWindowManager)

---

## Prerequisites

- [ ] Homebrew tap transferred `jimbarritt/homebrew-tap` → `ubiqtek` org
- [ ] New repo `github.com/ubiqtek/tilr` created
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

## Delta 7 — State file

**Goal:** state survives restart; active space restored on launch.

- [ ] `StateStore` with Combine publisher for `activeSpace`
- [ ] Loads/saves `~/Library/Application Support/tilr/state.toml`
- [ ] Hotkey fire → `StateStore.setActive(name)` persists & publishes
- [ ] Never writes to user `config.toml`
- [ ] `tilr status` reports `activeSpace`; new CLI command `tilr switch <name>`

**Notes:**

---

## Delta 8 — Menu bar title

**Goal:** menu bar always shows current space name in brackets.

- [ ] `MenuBarController` subscribes to `StateStore.$activeSpace`
- [ ] `NSStatusItem.button.title` updates live
- [ ] Format: `[Coding]`, `[Reference]`, `[Scratch]`

**Notes:**

---

## Delta 9 — Polish

**Goal:** shippable starter.

- [ ] Config file watch → hot reload on save
- [ ] Launch at login via `SMAppService`
- [ ] App icon finalised
- [ ] About dialog polished

**Notes:**

---

## Decision log

Record any plan deviations here with a date and one-line reason. Link to an
ADR in `doc/adr/` if the change is architectural.
