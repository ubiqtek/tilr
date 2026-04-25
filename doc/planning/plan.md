# Tilr — Delta Progress

Working tracker for the starter app build plan in
[`../kb/starter-app-plan.md`](../kb/starter-app-plan.md). Update this as each delta
lands — check boxes, add a dated note, link the commit/PR.

**Status legend:** ⬜ not started · 🟡 in progress · ✅ done · ⏭️ skipped

---

## Snapshot

| Delta | Title | Status | Landed |
|---|---|---|---|
| 0–5b | Core infrastructure | ✅ | 2026-04-18 |
| 6 | App visibility | ✅ | 2026-04-19 |
| 7 | App layout | ✅ | 2026-04-20 |
| 8 | Moving apps to a space | ✅ | 2026-04-25 |
| 9 | Follow focus on CMD-TAB | 🟡 | — |
| 10 | Multi-display support | ⬜ | — |
| 11 | State file | ⬜ | — |
| 12 | Polish | ⬜ | — |

**Current focus:** Delta 9 — Follow focus on CMD-TAB (cross-space switching pending)

---

## Prerequisites

- [ ] Homebrew tap transferred `jimbarritt/homebrew-tap` → `ubiqtek` org
- [x] New repo `github.com/ubiqtek/tilr` created
- [ ] Ubiqtek Developer ID cert available on this machine

---

## Delta details

- [Delta 0–5b: Core infrastructure](delta-0-5b.md)
- [Delta 1: Popup alert](delta-1.md)
- [Delta 2: Hotkey → popup](delta-2.md)
- [Delta 3: CLI scaffolding + health](delta-3.md)
- [Delta 4: Config (YAML, domain model, CLI commands)](delta-4.md)
- [Delta 5: Hotkeys from config + menu bar title + popup config](delta-5.md)
- [Delta 5b: Display configuration](delta-5b.md)
- [Delta 6: App visibility (AppWindowManager)](delta-6.md)
- [Delta 7: App layout](delta-7.md)
- [Delta 8: Moving apps to a space](delta-8.md)
- [Delta 9: Follow focus on CMD-TAB](delta-9.md)
- [Delta 10: Multi-display support](delta-10.md)
- [Delta 11: State file](delta-11.md)
- [Delta 12: Polish](delta-12.md)

---

## Known bugs (as of 2026-04-23)

- ~~**BUG-3**: Zen fill-screen → sidebar snap-back~~ — no longer observed, likely resolved
- ~~**BUG-4**: Zen not filling screen when moved to Reference~~ — no longer observed, likely resolved
- **BUG-5**: CMD+TAB sidebar handoff has ~200ms animation lag (AX readiness delay after unhide)
- ~~**BUG-6**: Moving Marq to Reference briefly shows full screen then all windows hide~~ — **Fixed (2026-04-23)**
  - Root cause: `handleSpaceActivated` fill-screen branch ignored `pendingMoveInto`/move override, showing the wrong app (previous `fillScreenLastApp`) instead of the moved app. Then `retryUntilWindowMatches` tried to frame the moved app while it was hidden → flash.
  - Fix: (a) Set `fillScreenLastApp[targetName] = bundleID` before `switchToSpace` so the standard path picks up the moved app. (b) Wire `retryUntilWindowMatches` in `handleSpaceActivated` for fill-screen targets so the resize retries until the window actually settles (~360ms in practice).
  - Also fixed: hotkey re-registration on every move (was subscribing to `configStore.$current` without filtering for hotkey-relevant changes).

---

## Decision log

Record any plan deviations here with a date and one-line reason. Link to an
ADR in `doc/adr/` if the change is architectural.
