# Implementation Note 005 — TilrLogger Concurrent-Writer Race Fixed with O_APPEND

**Date:** 2026-05-03  
**Status:** Complete  
**Relates to:** BUG-9 investigation, TilrLogger

## Summary

Fixed a concurrent-writer race condition in TilrLogger.swift where the long-running Tilr.app daemon and short-lived tilr CLI process both write to the same log file. FileHandle tracked an internal per-process write offset that became stale when a second process wrote past it, causing the first process's next write to overwrite bytes at the stale offset. Fixed by using POSIX `open(2)` with `O_APPEND` flag, which makes the kernel atomically reposition every write to the true EOF regardless of process state.

## Root Cause

`FileHandle(forWritingAtPath:)` opens a file and remembers the process's internal write offset. When two processes open the same file:

1. CLI opens and seeks to EOF (e.g., byte 5000)
2. CLI writes 50 bytes (START marker); kernel updates inode's EOF to 5050
3. CLI closes handle; its write offset is forgotten
4. Daemon has been holding its own handle open with stale offset still at byte 4900
5. Daemon writes 100 bytes from offset 4900, overwriting the CLI's 50 bytes (bytes 4900–4950)
6. Result: 50 bytes of CLI START marker are stomped, EOF is now 5000

The bug was masked by `tail -f` (which reads forward from where it opened) briefly showing the marker before it vanished, but `grep` on the file found nothing because those bytes had been overwritten on disk.

## Fix

Changed `openHandle()` in TilrLogger.swift to use POSIX `open(2)` with `O_APPEND | O_WRONLY | O_CREAT`:

**Before:**
```swift
FileHandle(forWritingAtPath: path)
```

**After:**
```swift
let fd = open(path.cString(using: .utf8)!, O_WRONLY | O_APPEND | O_CREAT, 0o644)
// ... use FileHandle(fileDescriptor:) with O_APPEND fd
```

With `O_APPEND`, the kernel atomically repositions every `write(2)` call to the current true EOF before writing, independent of the process's internal offset tracking. This makes concurrent writes safe: each process's write lands at the real EOF, never clobbering prior writes.

## Symptom That Revealed It

CLI ran `tilr debug-marker "START[HST-bc4b40]"`, writing a 30-byte marker. Immediately after:
- `tail -f ~/.local/share/tilr/tilr.log` showed the START marker briefly
- `grep -A 10 "START\[HST" ~/.local/share/tilr/tilr.log` returned nothing
- `tail -c 100 ~/.local/share/tilr/tilr.log` showed the END marker but not the START

This happened because:
1. CLI's marker was written to disk
2. `tail -f` was already watching the file, so it read the new bytes immediately
3. Daemon's subsequent write (from its stale offset) overwrote the CLI's bytes on disk
4. `grep` read the file after the overwrite and found no START marker
5. END marker survived only because no daemon write occurred after it
