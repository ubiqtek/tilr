# Logging and Debugging

## Overview

Tilr uses a file-based logging system with debug markers for investigation. All logs are written to `~/.local/share/tilr/tilr.log` with automatic rolling when the file exceeds 5 MB.

## Log File Location and Rotation

**Log file:** `~/.local/share/tilr/tilr.log`

- Thread-safe writes via a dedicated serial `DispatchQueue`.
- Automatic rolling: when the log exceeds 5 MB, it is renamed to `tilr.log.1` and a new `tilr.log` is created.
- Timestamp format: ISO8601 UTC (e.g., `2026-04-25T18:31:08.009Z`).

## Log Format

Each line follows one of two patterns:

### Standard log lines

```
<timestamp> [<category>] <message>
```

Examples:
```
2026-04-25T18:31:17.036Z [windows] applying space 'Coding': showing [Marq, Ghostty], hiding [Zen, 1Password, Claude, Notes, Safari]
2026-04-25T18:33:42.398Z [hotkey] Registered cmd+opt+1 for space 'Coding'
2026-04-25T18:31:08.009Z [layout] setWindowFrame: 'com.jimbarritt.marq' pos=0 size=0
```

Common categories:
- `[app]` — app lifecycle (starting, stopping)
- `[space]` — space switching, activation
- `[windows]` — window visibility, AX operations
- `[layout]` — layout application, frame sizing
- `[hotkey]` — hotkey registration, dispatch
- `[verify]` — window placement verification attempts and outcomes (critical for debugging)

### Debug markers

```
<timestamp> [MARKER] --- <description> ---
```

Example:
```
2026-04-25T17:14:16.572Z [MARKER] --- TEST: Snappier fill-screen resize with 100ms delay ---
```

Markers are visually distinct and serve as breakpoints in the log for tracking test/debug sessions.

## Using `tilr debug-marker`

The CLI command `tilr debug-marker <description>` writes a marker to the log file. Markers are useful for:

- Bracketing test scenarios (mark before and after a reproduction).
- Synchronizing manual actions with log timestamps.
- Highlighting specific sections of the log for analysis.

### Example workflow

```bash
# Terminal 1: start tailing the log
tail -f ~/.local/share/tilr/tilr.log

# Terminal 2: run a test and mark it
tilr debug-marker "before switching to Reference space"
# ... switch to Reference space manually via hotkey ...
tilr debug-marker "after switching to Reference space"

# In Terminal 1, search for your markers to find the relevant log section:
# [MARKER] --- before switching to Reference space ---
# [space] switching to 'Reference' (hotkey)
# ...
# [MARKER] --- after switching to Reference space ---
```

## Verification log lines

The most important log category for debugging space/layout changes is `[verify]`. These lines report the outcome of window placement verification:

```
verify: '<bundleID>' matches on attempt <N> (w=<width>)
verify: '<bundleID>' gave up after <N> attempts (want w=<targetWidth>, got w=<actualWidth>)
```

The verify lines indicate:
- Whether the window resized to its target size within tolerance (2px).
- On success: the attempt number (1 = snappy, >1 = retried).
- On failure: the target width, actual width, and retry attempts exhausted.

**Width is the primary check** because macOS menu bar clamps height (~34px difference), making height unreliable. Tilr compares only window width; if width matches, the window is correctly placed.

## Debugging a space switch or move-window issue

1. **Write a before marker:**
   ```bash
   tilr debug-marker "TEST: switching to Coding space with Ghostty, Marq visible"
   ```

2. **Reproduce the issue** — e.g., press `Cmd+Opt+1` to switch to Coding, or move an app via a hotkey.

3. **Write an after marker:**
   ```bash
   tilr debug-marker "after: result — Ghostty and Marq should be visible"
   ```

4. **Inspect the log between markers:**
   ```bash
   grep -A 50 "TEST: switching to Coding space" ~/.local/share/tilr/tilr.log
   ```

5. **Look for key events:**
   - `[space] switching to 'Coding'` — the space switch was triggered.
   - `[windows] applying space 'Coding': showing [...], hiding [...]` — which apps are made visible.
   - `[layout] setWindowFrame:` — the main window resize call (multiple lines for each window).
   - `[verify:` — the final placement result (matches, or gave up after N attempts).

## Log file cleanup

The log file is managed automatically and rolls over at 5 MB. To manually reset a session:

```bash
rm ~/.local/share/tilr/tilr.log
# Tilr will create a new one on next log write
```

Or to clear the log while keeping the rollover:

```bash
: > ~/.local/share/tilr/tilr.log
```

## Integration with testing

In test scenarios, markers are written just before and after a manual reproduction step:

```swift
// In test verification scripts or manual session docs:
// 1. tilr debug-marker "TEST: move Safari to Sidebar space via cmd+shift+opt+s"
// 2. [manually press cmd+shift+opt+s]
// 3. tilr debug-marker "verify: Safari visible in Sidebar sidebar region"
// 4. grep -B5 -A15 "move Safari" ~/.local/share/tilr/tilr.log
```

This pattern is the standard approach for debugging window management and layout issues in Tilr development.
