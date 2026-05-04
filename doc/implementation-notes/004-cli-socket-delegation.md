# Implementation Note 004 — CLI Socket Delegation for App Visibility Control

**Date:** 2026-05-03  
**Status:** Complete  
**Relates to:** BUG-9 investigation, CLI refactoring

## Summary

Refactored the `tilr apps` CLI command to delegate hide/show operations to the running Tilr.app via socket IPC, using the same `setAppHidden()` code path as space switching. This ensures CLI control uses identical hide/retry/logging mechanisms.

## Changes

### CLI Interface

Changed from subcommand structure to positional arguments:

**Before:**
```bash
tilr apps show Zen
tilr apps hide Zen
```

**After:**
```bash
tilr apps Zen show
tilr apps Zen hide
```

### Implementation

1. **TilrCLI.swift** — `Apps` command refactored to:
   - Accept two positional arguments: `nameOrBundleId` and `action` (show|hide)
   - Resolve app name/bundle ID to bundle ID using `resolveApp()`
   - Send `TilrRequest` via socket with cmd `"apps-show"` or `"apps-hide"` and bundleID parameter
   - Error handling identical to other socket commands (`status`, `reload-config`)

2. **Protocol.swift** — Extended `TilrRequest` with optional `bundleID` parameter:
   ```swift
   public struct TilrRequest: Codable {
       public let cmd: String
       public let bundleID: String?
   }
   ```

3. **CommandHandler.swift** — Added socket handlers for `"apps-show"` and `"apps-hide"`:
   ```swift
   case "apps-show", "apps-hide":
       guard let bundleID = request.bundleID else {
           return (TilrResponse(ok: false, error: "missing bundleID"), nil)
       }
       let hidden = request.cmd == "apps-hide"
       let postSend: (() -> Void)? = {
           DispatchQueue.main.async {
               setAppHidden(bundleID: bundleID, hidden: hidden)
           }
       }
   ```

## Code Path Guarantee

The CLI now uses the **exact same code path** as space switching:

- **Space switch** (AppWindowManager.handleSpaceActivated, lines 472, 481):
  ```swift
  setAppHidden(bundleID: bundleID, hidden: false)  // show
  setAppHidden(bundleID: bundleID, hidden: true)   // hide
  ```

- **CLI via socket** (CommandHandler, line 76):
  ```swift
  setAppHidden(bundleID: bundleID, hidden: hidden)
  ```

Both call the same `setAppHidden()` function in Layouts/AXWindowHelper.swift, which:
- Records intent in `intendedHiddenState` for retry chain self-cancellation
- Calls `setHiddenViaSystemEvents()` for hide (the Zen invariant)
- Calls `app.unhide()` for show
- Schedules up to 5 retries at 0.3s intervals to catch state drift

## Logging

When using `tilr apps Zen hide`, the log will show:
```
[hide] setAppHidden: 'app.zen-browser.zen' hidden=true isHidden=false
[hide] retry: 'app.zen-browser.zen' desiredHidden=true isHidden=true remaining=4
```

This logging is identical to space-switching logging, enabling consistent debugging.

## Benefits

1. **Consistency** — CLI control now uses the proven space-switching code path instead of ad-hoc AppKit/osascript calls
2. **Reliability** — Retry chains and state drift detection work for CLI just as they do for spaces
3. **Debugging** — All hide/show operations (whether from space switch or CLI) produce identical log output with `[hide]` markers
4. **Testability** — CLI can now be used to test hide/show mechanics independently of space switching, isolating BUG-9 issues

## Testing

To verify the refactoring:

1. Start the app: `open -a Tilr.app`
2. Mark the log: `tilr debug-marker "testing CLI hide"`
3. Test: `tilr apps zen hide`
4. Observe log output: `grep -A 2 "testing CLI hide" ~/.local/share/tilr/tilr.log`

The `[hide]` lines should show the same retry chain behavior as space switching.
