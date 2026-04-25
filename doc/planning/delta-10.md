# Delta 10 — Multi-display support

**Goal:** Assign spaces to specific displays; on multi-display systems, apps move to their configured display when switching spaces.

## Domain model — `Sources/Shared/Config.swift`

Extend `DisplayConfig` (introduced in Delta 5b) with:

```swift
public struct DisplayConfig: Codable {
    public var name: String?                     // user-chosen label e.g. "Main"
    public var defaultSpace: String?             // space name or space id (resolved at runtime)
    public var assignedSpaces: [String]?         // space names assigned to this display
    public init(name: String? = nil, defaultSpace: String? = nil, assignedSpaces: [String]? = nil) { ... }
}
```

Example YAML:
```yaml
displays:
  "1":
    name: Main
    defaultSpace: Coding
    assignedSpaces: [Coding, Reference]
  "2":
    name: Secondary
    defaultSpace: Scratch
    assignedSpaces: [Scratch]
```

## On space activation — `Sources/Tilr/AppWindowManager.swift`

When `handleSpaceActivated` is called:
- Resolve the target space's assigned display ID from config
- For each visible app in the space: move its windows to that display via AX
- Helper: `moveWindowToDisplay(window: AXUIElement, displayID: Int)`

Edge cases:
- Single-display systems: all spaces default to display 1 (no-op movement)
- App window not yet initialized: skip, don't crash
- AX movement fails: log warning, continue

## CLI — `Sources/TilrCLI/TilrCLI.swift`

Update existing `Displays` command group:

**`tilr displays assign-space <display-id> <space-name>`**
- Load config, add `spaceName` to `displays[displayId].assignedSpaces` (create if needed), save
- Validate space exists; error if not
- Print confirmation: `Space 'Coding' assigned to display 1 (Main)`

## Verification

1. Multi-display setup (e.g. laptop + external monitor):
   - Configure display 2 as default for "Scratch" space
   - Switch to Scratch: apps move to display 2
   - Drag window from display 1 to display 2 manually: stays on display 2 (app now considers it moved)
2. Single-display systems: behaviour unchanged, no errors
3. `tilr displays assign-space` command works and persists

## Notes

This is the last feature before "launchable product" status. Multi-display is common among the target user base and completes the core spatial management feature set.
