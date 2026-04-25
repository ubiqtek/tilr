# Delta 5b — Display configuration

**Goal:** display config section in YAML; `tilr displays list` / `configure`; on-launch jump to default space.

## Domain model — `Sources/Shared/Config.swift`

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

## CLI — `Sources/TilrCLI/TilrCLI.swift`

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

## On-launch behaviour — `Sources/Tilr/AppDelegate.swift`

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

## Deliverables checklist

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
