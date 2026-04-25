# Delta 3 — CLI scaffolding + health

**Goal:** `tilr` CLI binary exists, can query app health via Unix-domain
socket, and can stream logs. No config dependency — stands alone for
debugging.

## Target layout

- App target renamed `Tilr` → `TilrApp`, `PRODUCT_NAME=Tilr` → `Tilr.app`
- New target `TilrCLI`, `PRODUCT_NAME=tilr` → `tilr` binary
- New shared sources dir `Sources/Shared/` compiled into both targets

## Protocol

- Unix-domain socket at `~/Library/Application Support/tilr/tilr.sock`
- Newline-delimited JSON request/response
- First commands:
  - `status` → `{ok, pid, uptimeSeconds, spacesCount, activeSpace}`

## CLI commands (via Swift ArgumentParser)

- `tilr status`
  - App running → prints health table, exit 0
  - App not running (ECONNREFUSED / ENOENT) → prints
    `Tilr.app is not running.\n\n  Start with: open -a Tilr.app`, exit 1
- `tilr logs`
  - Wraps `/usr/bin/log stream --predicate 'subsystem == "io.ubiqtek.tilr"' --style compact`
  - No IPC — works whether app is running or not
- `tilr logs --last 100` (nice-to-have, via `log show`)

## Deliverables

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
