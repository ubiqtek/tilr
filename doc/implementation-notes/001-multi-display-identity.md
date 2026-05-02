# Multi-display identity and naming

## How stable IDs work

`tilr displays list` used to assign IDs by enumerating `NSScreen.screens` in order — this is unstable, IDs shift when a monitor is unplugged.

The fix: `DisplayStateStore` (`Sources/Shared/DisplayStateStore.swift`) persists a `[UUID: Int]` mapping to `~/Library/Application Support/tilr/display-state.json`.

Display UUID is obtained via `CGDisplayCreateUUIDRef` — but that function is not available in the macOS 13+ public SDK, so instead we use a composite of `CGDisplayVendorNumber + CGDisplayModelNumber + CGDisplaySerialNumber` formatted as `%08X-%08X-%08X`. This is stable across reboots and plug/unplug cycles.

On first sight of a display, the next available integer ID is auto-assigned and persisted. The user can later reassign IDs with `tilr displays configure <id> --number <n>`.

## Verified behaviour

Test results from 2026-05-02 demonstrate that IDs stay stable across plug/unplug cycles.

**All three connected:**

```
ID  Tilr Name   System Name               Default Space  UUID
--  ---------   -----------               -------------  ----
1   Primary     Built-in Retina Display   Home           XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
2   Left        External Monitor A        —              YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY
3   Centre      External Monitor B        —              ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ
```

**After unplugging Left (ID 2 absent, Centre keeps ID 3):**

```
ID  Tilr Name   System Name               Default Space  UUID
--  ---------   -----------               -------------  ----
1   Primary     Built-in Retina Display   Home           XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
3   Centre      External Monitor B        —              ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ
```

**After unplugging Centre (only Primary and Left connected, Left keeps ID 2):**

```
ID  Tilr Name   System Name               Default Space  UUID
--  ---------   -----------               -------------  ----
1   Primary     Built-in Retina Display   Home           XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
2   Left        External Monitor A        —              YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY
```

**Key observation:** IDs do not shift when a display is removed. Each display retains its assigned ID regardless of which others are connected.

## Naming displays

- `tilr displays configure <id> --name <label>` sets the Tilr name (stored in config `~/.config/tilr/config.yaml` under `displays.<id>.name`).
- `tilr displays configure <id> --default-space <space>` sets the default space (optional).
- `tilr displays configure <id> --number <n>` reassigns the integer ID (updates both state and config key).
- `tilr displays identify` flashes a labelled popup on each connected display simultaneously (3s duration) showing `<id> · <name>` — useful for figuring out which physical monitor maps to which ID.

## State file location

Display state is persisted to `~/Library/Application Support/tilr/display-state.json`.

Example with three displays registered:

```json
{
  "nextId": 4,
  "uuidToId": {
    "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX": 1,
    "YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY": 2,
    "ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ": 3
  }
}
```

`nextId` is the next integer to assign when a new display is seen for the first time.
