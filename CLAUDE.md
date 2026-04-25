# CLAUDE.md

Tilr — native macOS workspace manager. Replaces a Hammerspoon-based
implementation that still lives in the user's dotfiles.

## Where to start

- **`doc/kb/specifications.md`** — product and engineering specification
- **`doc/kb/starter-app-plan.md`** — Delta 0–7 build plan for the starter app
- **`doc/adr/`** — architecture decision records

Read the KB docs before suggesting architecture or scope changes.

## Conventions

- Native macOS app (Swift, AppKit + SwiftUI)
- Published under **Ubiqtek Ltd** — bundle ID `io.ubiqtek.tilr`, distributed
  via `ubiqtek/tap` Homebrew cask
- Two-file state model: `~/.config/tilr/config.toml` (user-owned) vs
  `~/Library/Application Support/tilr/state.toml` (app-owned runtime state).
  Never write to the user config.

## Logging and debugging

Tilr uses a file-based logging system to track space switches, window placement,
and layout operations. Logs are written to `~/.local/share/tilr/tilr.log` with
automatic rolling at 5 MB.

**Key log categories:** `[space]`, `[windows]`, `[layout]`, `[verify]`
(most important for debugging window placement issues).

**Debug markers:** Use `tilr debug-marker "<description>"` to write a visually
distinct marker line to the log. Markers are useful for bracketing test
scenarios and pinpointing log sections for analysis.

**Debugging workflow:**
1. `tilr debug-marker "TEST: before reproduction"`
2. Reproduce the issue (e.g., press hotkey, move window).
3. `tilr debug-marker "TEST: after reproduction"`
4. `grep -A 50 "before reproduction" ~/.local/share/tilr/tilr.log`
5. Look for `[verify:` lines — they show window placement attempts and outcomes.

For detailed guide, see **`doc/arch/logging.md`**.

## Upstream reference

The Hammerspoon Lua implementation is the behavioural spec for the full native
port. It lives in two locations:

- **`~/projects/dotfiles/home/hammerspoon/init.lua`** — symlinked working copy
  (use this when reading code during a session)
- `~/Code/github/jimbarritt/dotfiles/home/hammerspoon/init.lua` — git repo

Key sections to reference:
- **Alert style** (line ~94): Menlo 30pt, `#00ff88` green on `#1a1a2e` navy,
  fade in 0.1s / hold 1.2s / fade out 0.15s
- **Status overlay** (line ~379): `cmd+alt+space` toggle, shows all spaces +
  active screen per space
- **Hotkey binding** (line ~505): `bindKey` wrappers, config-driven space keys
