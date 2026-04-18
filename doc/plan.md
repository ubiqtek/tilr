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
| 5 | Hotkeys from config | ⬜ | — |
| 6 | State file | ⬜ | — |
| 7 | Menu bar title | ⬜ | — |
| 8 | Polish | ⬜ | — |

**Current focus:** Delta 5 — Hotkeys from config

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

## Delta 5 — Hotkeys from config

**Goal:** config-driven hotkeys, popup shows space name.

- [ ] `HotKeyManager` registers one HotKey per configured space
- [ ] Press → popup shows that space's name
- [ ] Collision/invalid-hotkey handling is at least logged

**Notes:**

---

## Delta 6 — State file

**Goal:** state survives restart; active space restored on launch.

- [ ] `StateStore` with Combine publisher for `activeSpace`
- [ ] Loads/saves `~/Library/Application Support/tilr/state.toml`
- [ ] Hotkey fire → `StateStore.setActive(name)` persists & publishes
- [ ] Never writes to user `config.toml`
- [ ] `tilr status` reports `activeSpace`; new CLI command `tilr switch <name>`

**Notes:**

---

## Delta 7 — Menu bar title

**Goal:** menu bar always shows current space name in brackets.

- [ ] `MenuBarController` subscribes to `StateStore.$activeSpace`
- [ ] `NSStatusItem.button.title` updates live
- [ ] Format: `[Coding]`, `[Reference]`, `[Scratch]`

**Notes:**

---

## Delta 8 — Polish

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
