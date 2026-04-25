# Delta 4 — Config (YAML, domain model, CLI commands)

**Goal:** config parsed from YAML, domain model established, CLI commands to inspect and manipulate config.

## Format

- Replace `TOMLKit` with `Yams` SPM package
- Config file: `~/.config/tilr/config.yaml`
- Missing file → write default (empty spaces, default shortcuts) and continue

## Default config written on first launch

```yaml
keyboardShortcuts:
  switchToSpace: cmd+opt
  moveAppToSpace: cmd+shift+opt

spaces: {}
```

## Domain model — `Sources/Shared/Config.swift`

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

## Example config (Hammerspoon-equivalent spaces)

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

## Tests first — `TilrCoreTests` target

- Parse above YAML string → assert 3 spaces, IDs, apps, shortcuts, layout fields
- Derived hotkey: `Coding` space → `cmd+opt+1`
- Missing `layout` → `nil` on Reference/Scratch
- Default config round-trips cleanly (write → parse → write → identical)
- Malformed YAML → throws

## App side

- [x] Swap `TOMLKit` → `Yams` in `project.yml`
- [x] `Sources/Shared/Config.swift` — domain model types above
- [x] `Sources/Tilr/ConfigLoader.swift` — `load()` reads `~/.config/tilr/config.yaml`; missing file → write default and return it; malformed → log error, return nil
- [x] `AppDelegate` loads config on launch, logs space count
- [x] `tilr status` reports real `Spaces` count (socket `StatusData.spacesCount`)

## CLI commands

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
