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
| 9 | Follow focus on CMD-TAB | ✅ | 2026-04-25 |
| 10 | Sidebar layout on app activate/close | ✅ | 2026-04-27 |
| 11 | Multi-display support | 🟡 | — |
| 12 | Version management | ✅ | 2026-05-03 |
| 13 | Rearchitect to pipeline | 🟡 | — |
| 14 | State file | ⬜ | — |
| 15 | Polish | ⬜ | — |
| 16 | Release on App Store | ⬜ | — |

**Current focus:** Delta 13: Rearchitect to pipeline (Delta 1: app startup + state initialization + CLI observability)

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
- [Delta 10: Sidebar layout on app activate/close](delta-10.md)
- [Delta 11: Multi-display support](delta-11.md)
- [Delta 12: Version management](delta-12.md)
- [Delta 13: Rearchitect to pipeline](delta-13.md)
- [Delta 14: State file](delta-14.md)
- [Delta 15: Polish](delta-15.md)
- [Delta 16: Release on App Store](delta-16.md)

---

## Known bugs (as of 2026-04-25)

- ~~**BUG-3**: Zen fill-screen → sidebar snap-back~~ — no longer observed, likely resolved
- ~~**BUG-4**: Zen not filling screen when moved to Reference~~ — no longer observed, likely resolved
- **BUG-5**: CMD+TAB sidebar handoff has ~200ms animation lag (AX readiness delay after unhide)
- ~~**BUG-6**: Moving Marq to Reference briefly shows full screen then all windows hide~~ — **Fixed (2026-04-23)**
  - Root cause: `handleSpaceActivated` fill-screen branch ignored `pendingMoveInto`/move override, showing the wrong app (previous `fillScreenLastApp`) instead of the moved app. Then `retryUntilWindowMatches` tried to frame the moved app while it was hidden → flash.
  - Fix: (a) Set `fillScreenLastApp[targetName] = bundleID` before `switchToSpace` so the standard path picks up the moved app. (b) Wire `retryUntilWindowMatches` in `handleSpaceActivated` for fill-screen targets so the resize retries until the window actually settles (~360ms in practice).
  - Also fixed: hotkey re-registration on every move (was subscribing to `configStore.$current` without filtering for hotkey-relevant changes).
- ~~**BUG-7**: Cross-space follow-focus recursed into source space~~ — **Fixed (2026-04-25)**
  - Root cause: when `handleSpaceActivated` hides the previously-frontmost app, macOS auto-promotes another visible app, firing our `handleAppActivation`. With `isTilrActivating` guard still false, the cross-space follow-focus would recursively switch back to the source space.
  - Fix: set `isTilrActivating = true` at the very START of `handleSpaceActivated` (not inside the delayed asyncAfter), with a 0.6s reset. Captures the guard correctly for all activation events triggered by subsequent `app.activate()` calls.
- ~~**BUG-8**: moveCurrentApp's deferred layout never ran after Delta 9~~ — **Fixed (2026-04-25)**
  - Root cause: removed `.receive(on:)` hop from SpaceService's onSpaceActivated subscriber (see decision log). That hop was queuing `handleSpaceActivated` to the next runloop tick, breaking the capture order of the generation token in `moveCurrentApp`.
  - Fix: run `handleSpaceActivated` synchronously within the subscription's `send()` call. Adjusted `moveCurrentApp` gen capture position to AFTER switchToSpace (now matches what `handleSpaceActivated` set).
- **BUG-9**: Zen not hidden when switching to Coding after Reference → Scratch → Coding sequence — *fix applied 2026-05-03, needs testing*
  - Root cause: `guard !app.isHidden else { continue }` in `setAppHidden` skipped both the hide call AND retry scheduling when Zen was already hidden (from Scratch). When Coding fired, no safety net existed.
  - Fix: Removed the guard; added immediate `setHiddenViaSystemEvents` call on hide path. `NSRunningApplication.hide()` is silently ignored by Zen (Firefox/Gecko arch) — SystemEvents is the only reliable mechanism. See `doc/implementation-notes/003-zen-browser-hide-unreliability.md`.

---

## Decision log

Record any plan deviations here with a date and one-line reason. Link to an
ADR in `doc/adr/` if the change is architectural.

- **2026-04-25:** Adopted generation-token pattern (UInt64 counter in AppWindowManager, captured by asyncAfter blocks, guards against stale work from rapid space switches). See `doc/arch/async-and-races.md`.
- **2026-04-25:** Removed `.receive(on:)` hop from SpaceService's onSpaceActivated subscriber; handlers must run synchronously inside `send()` for generation-token capture order to be correct. See `doc/arch/async-and-races.md`.
- **2026-05-02:** Delta 11 display identity foundation complete. `DisplayStateStore` + stable UUID→integerID mapping landed; `tilr displays list/configure/identify/config` all working. Per-display active space in `SpaceService` is next.
- **2026-05-02:** Delta 11 step 2 complete. DisplayResolver shim landed; 6 NSScreen.main call sites in AppWindowManager refactored. Behavior unchanged (resolver returns .main).
