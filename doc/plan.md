# Tilr — Delta Progress

Working tracker for the starter app build plan in
[`kb/starter-app-plan.md`](kb/starter-app-plan.md). Update this as each delta
lands — check boxes, add a dated note, link the commit/PR.

**Status legend:** ⬜ not started · 🟡 in progress · ✅ done · ⏭️ skipped

---

## Snapshot

| Delta | Title | Status | Landed |
|---|---|---|---|
| 0 | Skeleton | ✅ | 2026-04-17 |
| 1 | Popup alert | ✅ | 2026-04-17 |
| 2 | Hotkey → popup | ✅ | 2026-04-17 |
| 3 | Config loading | ⬜ | — |
| 4 | Hotkeys from config | ⬜ | — |
| 5 | State file | ⬜ | — |
| 6 | Menu bar title | ⬜ | — |
| 7 | Polish | ⬜ | — |

**Current focus:** Delta 3 — Config loading

---

## Prerequisites

- [ ] Homebrew tap transferred `jimbarritt/homebrew-tap` → `ubiqtek` org
- [ ] New repo `github.com/ubiqtek/tilr` created
- [ ] Ubiqtek Developer ID cert available on this machine

---

## Delta 0 — Skeleton

**Goal:** app runs, shows in menu bar, quits cleanly.

- [x] Xcode App project created, `LSUIElement=true`
- [x] SPM deps added: HotKey, TOMLKit
- [x] `NSStatusItem` with static title "Tilr"
- [x] Quit menu item wired up
- [x] App icon in asset catalogue

**Notes:**

---

## Delta 1 — Popup alert

**Goal:** popup triggerable from menu, positioned on focused screen.

- [x] Borderless `NSPanel` (nonactivating, transparent bg)
- [x] SwiftUI centre-label view (Menlo 30pt, #00ff88 on #1a1a2e, matching Lua style)
- [x] Fade in → hold → fade out
- [x] Help menu item shows keyboard shortcuts for 3s

**Notes:**

---

## Delta 2 — Hotkey → popup

**Goal:** global hotkey working, popup responds.

- [x] `cmd+opt+space` registered via HotKey
- [x] Press fires popup

**Notes:**

---

## Delta 3 — Config loading

**Goal:** config parsed, validated, sensible error if malformed.

- [ ] `SpaceConfig: Codable` struct
- [ ] `ConfigLoader.load()` via TOMLKit
- [ ] Reads `~/.config/tilr/config.toml` on launch
- [ ] Writes default config if missing
- [ ] Logs parsed spaces; clear error on malformed TOML

**Notes:**

---

## Delta 4 — Hotkeys from config

**Goal:** config-driven hotkeys, popup shows space name.

- [ ] `HotKeyManager` registers one HotKey per configured space
- [ ] Press → popup shows that space's name
- [ ] Collision/invalid-hotkey handling is at least logged

**Notes:**

---

## Delta 5 — State file

**Goal:** state survives restart; active space restored on launch.

- [ ] `StateStore` with Combine publisher for `activeSpace`
- [ ] Loads/saves `~/Library/Application Support/tilr/state.toml`
- [ ] Hotkey fire → `StateStore.setActive(name)` persists & publishes
- [ ] Never writes to user `config.toml`

**Notes:**

---

## Delta 6 — Menu bar title

**Goal:** menu bar always shows current space name in brackets.

- [ ] `MenuBarController` subscribes to `StateStore.$activeSpace`
- [ ] `NSStatusItem.button.title` updates live
- [ ] Format: `[Coding]`, `[Reference]`, `[Scratch]`

**Notes:**

---

## Delta 7 — Polish

**Goal:** shippable starter.

- [ ] Config file watch → hot reload on save
- [ ] Launch at login via `SMAppService`
- [ ] App icon finalised
- [ ] About dialog polished

**Notes:**

---

## Decision log

Record any plan deviations here with a date and one-line reason. Link to an
ADR in `doc/adr/` if the change is architectural.
