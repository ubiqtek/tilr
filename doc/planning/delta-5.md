# Delta 5 — Hotkeys from config + menu bar title + popup config

**Goal:** config-driven hotkeys; active space shown in menu bar; popup visibility controlled by config.

## Part A — `PopupConfig` in `TilrConfig`

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

## Part B — In-memory `StateStore`

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

## Part C — `HotKeyManager` reads config

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

## Part D — `MenuBarController` observes `StateStore`

- Add a `Combine` `AnyCancellable` to `MenuBarController`
- Subscribe to `stateStore.$activeSpace` on the main queue
- `nil` → title `"Tilr"`; `"Coding"` → title `"[Coding]"`
- `MenuBarController.init` gains a `stateStore: StateStore` parameter

## Part E — Wire up in `AppDelegate`

```swift
private let stateStore = StateStore()
```

Pass `stateStore` to `MenuBarController` and `HotKeyManager`.
Pass `config` to `HotKeyManager`.

## Deliverables checklist

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
