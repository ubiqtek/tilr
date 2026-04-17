# Tilr — Specifications

![Tilr icon](../images/tilr-icon.svg)

Native macOS workspace manager for per-display app grouping and fast
switching. Successor to a Hammerspoon-based implementation ("Tilr-Lua") that
lives in the author's dotfiles.

---

## 1. Origin

Tilr started as `init.lua` in the user's Hammerspoon config
(`~/Code/github/jimbarritt/dotfiles/home/hammerspoon/init.lua`, ~730 lines).
That version manages:

- Named "spaces" (Coding, Reference, Scratch, etc.), each with an app list
- **Hide/unhide-based switching** (like FlashSpace) — no native macOS Spaces,
  no Mission Control
- **Per-display** app grouping with per-space screen preference lists and a
  global screen precedence chain
- Sidebar layouts (optional, ratio-based)
- Global hotkeys to activate spaces
- Session overrides (temporary screen or app reassignment)
- Focus watcher, diagnostics dump, rolling config backups

The Lua version works but can't give a proper menu-bar experience, settings
UI, or clean distribution. Tilr (the native app) is the replacement.

---

## 2. Product goals

### Immediate — starter app scope (see `starter-app-plan.md`)

- Menu-bar display of the currently-active space: `[Coding]`, `[Reference]`, …
- Global hotkeys from TOML config that switch the active space
- Popup alert on space activation (replaces current `hs.alert.show`)
- TOML config (user-owned) + runtime state file (app-owned, separate)

### Full native parity (later)

- App hide/unhide via `NSRunningApplication`
- Window moves via Accessibility API (`AXUIElement`)
- Multi-monitor: per-screen active space, prefer lists, precedence chain
- Sidebar layouts with persisted ratios
- Session overrides (screen + app)
- Per-display menu bar (stretch — requires creative approach)

### Non-goals

- Not a native macOS Spaces replacement — same Mission Control space, always
  (FlashSpace model)
- Not a full tiling WM — sidebar layout only; free-floating otherwise
- Not a multi-user or team tool — single-machine, single-user config

---

## 3. Core concepts

### Space
A named bag of apps displayed on a preferred screen. Activating a space
unhides its apps on the target screen and hides every other non-exempt app
on that screen.

### Screen
A physical display, identified by logical name in config (`external-main`,
`external-secondary`, `laptop`). A UUID→name registry persists the mapping
so config survives display reconnects.

### Hide/unhide model
Apps not in the active space on a given screen are hidden via
`NSRunningApplication.hide()`. Windows of active apps are moved to the
target screen via `AXUIElement`. No native Spaces are used — everything
runs in the user's current Mission Control space.

---

## 4. Two-file state model

### `~/.config/tilr/config.toml` — user-owned, declarative

```toml
[[spaces]]
name = "Coding"
hotkey = "cmd+alt+1"

[[spaces]]
name = "Reference"
hotkey = "cmd+alt+2"

[[spaces]]
name = "Scratch"
hotkey = "cmd+alt+3"
```

Version-controllable. The app never writes to this file.

### `~/Library/Application Support/tilr/state.toml` — app-owned, runtime

```toml
[state]
active_space = "Coding"
last_changed = "2026-04-17T20:45:00+0100"

# future: session_screen_override, session_app_override, space ratios
```

Reset session = delete `state.toml`. Config is untouched.

**Why the split is load-bearing:**
- User config stays declarative and diffable
- Runtime writes (active space, future ratios, overrides) never churn the
  user config
- Clean way to reset session state without touching config

---

## 5. Tech stack

| Concern | Choice | Notes |
|---|---|---|
| Project type | Xcode app, `LSUIElement=true` | Real `.app` bundle for AX perms |
| Swift | 5.9+, Xcode 15+ | — |
| UI framework | AppKit primary, SwiftUI for popup | `NSStatusItem` is AppKit-only |
| Hotkeys | [soffes/HotKey](https://github.com/soffes/HotKey) via SPM | Carbon-based, stable |
| TOML | [LebJe/TOMLKit](https://github.com/LebJe/TOMLKit) via SPM | `Codable`-friendly |
| State | Combine publishers | Single source of truth = `StateStore` |

---

## 6. Architecture sketch

```
ConfigLoader        reads config.toml → [SpaceConfig]
StateStore          reads/writes state.toml; publishes activeSpace
SpaceRegistry       in-memory list of Spaces, built from ConfigLoader
HotKeyManager       registers HotKey per space; dispatches to SpaceActivator
SpaceActivator      activate(name): StateStore.setActive + PopupWindow.show
MenuBarController   owns NSStatusItem; observes StateStore.activeSpace
PopupWindow         borderless floating NSPanel with fade in/out
```

### Event flow

```
hotkey fires
  → SpaceActivator.activate("Coding")
    → StateStore.setActive("Coding")       (writes state.toml, publishes)
    → PopupWindow.show("Coding")           (borderless panel on focused screen)
  → MenuBarController observer
    → NSStatusItem.button.title = "[Coding]"
```

The `StateStore` is the single source of truth for runtime. Every UI surface
(menu bar, popup, future overlays) subscribes to it.

---

## 7. Publishing & distribution

- **Team / signer:** Ubiqtek Ltd (Apple Developer Program org enrollment)
- **Bundle ID:** `io.ubiqtek.tilr` (reverse DNS of `ubiqtek.io`)
- **Signing:** Developer ID Application cert, notarized via `notarytool`,
  stapled before distribution
- **Distribution:** Homebrew cask served from `ubiqtek/tap`
- **Repo:** `github.com/ubiqtek/tilr`

### Homebrew tap migration

The tap is moving from `jimbarritt/tap` to `ubiqtek/tap`. Transfer
`github.com/jimbarritt/homebrew-tap` → `github.com/ubiqtek/homebrew-tap` via
GitHub Settings → Transfer ownership; GitHub auto-redirects old URLs so
existing Marq users aren't forced to re-tap.

---

## 8. Relationship to Hammerspoon Tilr

During starter-app development, the Hammerspoon version remains the user's
daily driver. Swift Tilr is launched separately for testing — the user quits
Hammerspoon first to avoid hotkey collisions. The starter does no window
work, so there's nothing to collide beyond hotkey bindings.

Eventually Swift Tilr replaces the Hammerspoon implementation entirely. The
Lua version stays in `jimbarritt/dotfiles` as a historical reference and
behavioural spec.

---

## 9. See also

- [`starter-app-plan.md`](starter-app-plan.md) — concrete Delta 0–7 build plan
- `doc/adr/` — architecture decision records
- Upstream Lua implementation:
  `~/Code/github/jimbarritt/dotfiles/home/hammerspoon/init.lua`
- Related research docs:
  `~/Code/github/jimbarritt/dotfiles/doc/window-tiling-macos/`
  (FlashSpace reference, yabai reference, macOS native-spaces notes)
