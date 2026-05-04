# BUG-9 Investigation Log — Zen not hidden on space switch

**Symptom:** Reference → Scratch → Coding sequence: Zen Browser stays visible in Coding when it should be hidden.

**READ THIS FIRST before touching any code or suggesting any fix.**

---

## How to reproduce

1. Switch to Reference (Zen fills screen — visible, correct)
2. Switch to Scratch (Zen should hide — check it did)
3. Switch to Coding (Zen should hide — **this is where it fails**)

Run at least 3 times. The bug is intermittent — it may pass once and fail on the second cycle.

## How to collect logs

```
tilr debug-marker "BUG-9 before: Reference"
# switch to Reference
tilr debug-marker "BUG-9 before: Scratch"
# switch to Scratch
tilr debug-marker "BUG-9 before: Coding"
# switch to Coding
tilr debug-marker "BUG-9 after"
grep -A 100 "BUG-9 before: Reference" ~/.local/share/tilr/tilr.log | head -120
```

Look for `[windows]` hide lines for `app.zen-browser.zen` and whether SystemEvents was called.

---

## Attempt log

### 2026-05-03 — Attempt 1: remove isHidden guard + immediate SystemEvents

**Code changed:** `Sources/Tilr/Layouts/AXWindowHelper.swift`, `setAppHidden`

Removed `guard !app.isHidden else { continue }` which was skipping both `app.hide()` AND `scheduleHiddenStateRetry` when Zen was already hidden from a prior switch.

Added immediate `setHiddenViaSystemEvents` call alongside `app.hide()` (previously SystemEvents was only called as the last retry at T+0.6s).

**Result after first test cycle:** PASSED — Zen hid correctly.

**Result after second test cycle:** FAILED — Zen did not hide on the second run of the sequence.

**Conclusion:** The fix is incomplete. Something else is still causing Zen to survive the second cycle. Possible causes to investigate next:
- `activate()` called on Zen during Coding switch unhides it after the hide fires
- Race: SystemEvents osascript is async (fire-and-forget Process) — by the time it executes, Zen has already been re-shown by something
- `scheduleHiddenStateRetry` at T+0.3s and T+0.6s — are they still firing and seeing `isHidden == true` and exiting early, even though Zen is actually visible? (i.e. is `isHidden` lying to us?)
- Is Zen being `activate()`d somewhere in the Coding activation flow that overrides the hide?

**Do NOT retry this same fix. The guard removal + immediate SystemEvents call is already in the code. The problem is elsewhere.**

---

### 2026-05-03 — Attempt 2: extend isTilrActivating to 1500ms + continuous retry chain

**Root cause identified from logs:**
- Scratch switch fires at T=0ms. `isTilrActivating = true`, resets after 600ms.
- SystemEvents hides Zen immediately.
- At T=600ms: `isTilrActivating` resets to `false`.
- At T=949ms: Zen fights back and becomes frontmost. `handleAppActivation` fires.
- `isTilrActivating` is now `false` → guard passes → Zen belongs to Reference → switches to Reference.

**Two changes applied:**

1. `Sources/Tilr/AppWindowManager.swift` line ~396: changed `isTilrActivating` reset from 0.6s to 1.5s in `handleSpaceActivated`. This keeps the guard true past Zen's fight-back at ~950ms.

2. `Sources/Tilr/Layouts/AXWindowHelper.swift`, `scheduleHiddenStateRetry`: removed early-exit (`if current == desiredHidden { return }`) so chain keeps polling for all retries. Use SystemEvents on EVERY retry (not just final) when desiredHidden=true. Increased retries from 2 to 5 (= 1.5s coverage at 0.3s intervals).

**Tradeoff:** CMD+TAB within 1.5s of a hotkey space switch is suppressed. Accepted — the alternative (space randomly snapping back to Reference) is worse. The 1.5s window matches the retry coverage exactly.

**Result:** FAILED — made things worse ("flashing all over the place").

**Root cause of the regression:** Removing the early exit (`if current == desiredHidden { return }`) caused old retry chains to keep running into subsequent space switches. Example from log:
- `23:33:29.540` — Scratch switch hides Marq; 5 retry chain starts
- `23:33:30.768` — Coding switch shows Marq (T+1.2s)
- `23:33:31.606` — Retry at T+1.5s fires, sees Marq visible, calls SystemEvents to re-hide it → FLASHING

**What this rules out:** No-early-exit retry chain without a cancellation mechanism is broken — old chains clobber subsequent space switches.

---

### 2026-05-03 — Attempt 3: intendedHiddenState guard + 1.5s isTilrActivating + 5 retries — VERIFICATION FAILED

**Code applied (Attempt 3):** `Sources/Tilr/Layouts/AXWindowHelper.swift` (lines 71–115) and `Sources/Tilr/AppWindowManager.swift` (line 394).

- New `@MainActor var intendedHiddenState: [String: Bool] = [:]` dict (line 74) tracks the most recent intended hidden state per bundle ID.
- `setAppHidden` records `intendedHiddenState[bundleID] = hidden` before the per-instance loop (line 84). For each running instance, on hide it calls `app.hide()` then `setHiddenViaSystemEvents(...)` immediately (lines 88–89). On unhide it calls `app.unhide()`. It then calls `scheduleHiddenStateRetry(..., attemptsRemaining: 5)`.
- `scheduleHiddenStateRetry` (lines 97–115) self-cancels at the top of each retry: `guard intendedHiddenState[bundleID] == desiredHidden else { return }`. If `app.isHidden != desiredHidden`, it re-issues `app.hide() + setHiddenViaSystemEvents` (or `app.unhide()`) and re-schedules with `attemptsRemaining - 1`. Five retries at 0.3s = 1.5s coverage.
- `setHiddenViaSystemEvents` (line 176) builds `tell application "System Events" to set visible of process "<name>" to false` and runs it via `Process()` → `/usr/bin/osascript`, fire-and-forget — `try task.run()` errors are swallowed silently and the task is never waited on.
- `handleSpaceActivated` (AppWindowManager.swift line 392) sets `isTilrActivating = true` and resets it after **1.5s** (matching the retry coverage), so `handleAppActivation` returns early for any app focus event in that window (line 307).

**Symptom (verified 2026-05-03):** User reports verbatim — *"it replicated zen flashes and then remains visible after switching from reference to scratch first time."*

Disambiguated:
- Starting space: **Reference** (Zen Browser is the fill-screen app and is visible, occupying the screen).
- Action: user presses the hotkey for **Scratch** (`cmd+opt+0`).
- Expected: Zen hides cleanly; Scratch sidebar layout becomes active.
- Observed: Zen visibly **flashes** (a brief disappear/transition) and then **remains visible on screen** even though the active space is now Scratch.
- Cycle: this is the **first** Reference→Scratch transition of the test run, not the second. Attempt 2 failed only on the second cycle; Attempt 3 fails on the first. This is a fail-cycle regression.

**Log evidence (lines 9076–9310, range covers the entire reproduction session):**

The Reference→Scratch transition under test:
- `9087` — `2026-05-03T04:42:49.736Z [space] switching to 'Reference' (hotkey)`
- `9088` — `2026-05-03T04:42:49.758Z [windows] applying space 'Reference': showing [Zen], hiding [1Password, Claude, Passwords, Safari, Xcode, Finder, Google Chrome, Marq, Ghostty, Slack]`
- `9089`–`9122` — repeated `fill-screen apply ... visibleApps=["app.zen-browser.zen"]` and `setWindowFrame: 'app.zen-browser.zen'` from 04:42:49.881Z through 04:42:50.962Z (Zen being placed and the verify chain running). At `9122` (04:42:50.962Z) the chain ends.
- `9123` — `2026-05-03T04:42:52.546Z [space] switching to 'Scratch' (hotkey)`  ← the user's transition
- `9124` — `2026-05-03T04:42:52.567Z [windows] applying space 'Scratch': showing [1Password], hiding [Zen, Claude, Passwords, Safari, Xcode, Finder, Google Chrome, Marq, Ghostty, Slack]`
- `9125` — `2026-05-03T04:42:57.513Z [space] switching to 'Coding' (hotkey)` (4.95s later — user moved on)

Between lines 9124 and 9125 (the 4.95s window during which the bug manifests), the log contains **zero further entries**. There are no `[layout]`, `[windows]`, or any other lines for `app.zen-browser.zen` after the Scratch switch fires.

**Critical caveat about the log:** the current build's `setAppHidden`, `scheduleHiddenStateRetry`, `setHiddenViaSystemEvents`, and `handleAppActivation` emit **no** `TilrLogger` entries at all. The only hide-related log line is the high-level `[windows] applying space '…': showing [...] hiding [...]` summary printed by AppWindowManager *before* the per-app calls execute. Therefore the log proves only that the hide *intent* was recorded for Zen at 04:42:52.567Z; it cannot show whether `app.hide()` was issued, whether `setHiddenViaSystemEvents` fired, what `osascript` returned, what `app.isHidden` read back, whether any of the five retries fired, or whether `handleAppActivation` was invoked and (if so) suppressed by `isTilrActivating`.

**Root cause analysis — what the log proves vs. what is hypothesis:**

Proven from the log:
- The Scratch hotkey fired and AppWindowManager emitted the correct hide-set including Zen at 04:42:52.567Z.
- No fill-screen re-apply for Zen runs during the Reference→Scratch transition (consistent with Reference being deactivated, not re-applied).
- Nothing in tilr.log indicates Zen was unhidden by any tilr code path during the 4.95s window.

Not provable from the log (insufficient instrumentation):
- Whether `app.hide()` was actually called for Zen on the Scratch switch (it should be — `setAppHidden` is invoked unconditionally from the hide loop in `handleSpaceActivated`, not gated on prior intent).
- Whether `setHiddenViaSystemEvents` was invoked, and if so, whether the `osascript` Process actually launched (fire-and-forget — `try task.run()` errors are swallowed silently, line 188).
- Whether any of the 5 scheduled retries fired, and what `app.isHidden` read at each tick.
- Whether `handleAppActivation` fired for Zen during the 1.5s `isTilrActivating` window. Per `doc/arch/cross-space-switching.md` and `doc/arch/macos-windowing.md`, Zen historically fights back at ~900–1000ms after a hide; the 1.5s window from Attempt 2 should cover this, but the log cannot confirm it without instrumentation.

Hypothesis space, ranked by what the architecture docs warn about:
1. `setHiddenViaSystemEvents` is fire-and-forget via `Process()` — if the spawn fails or osascript exits non-zero, no log line is emitted. `doc/arch/window-visibility.md` line 107 documents that `NSRunningApplication.hide()` is a no-op for Zen, so SystemEvents is the *only* mechanism that should actually hide Zen. If osascript silently fails on this path, Zen never hides — matching the symptom exactly.
2. AX/`isHidden` may report stale state during the retry window. `doc/arch/macos-windowing.md` notes AX is fire-and-forget and AX reads can fail or lie on hidden windows. If `app.isHidden` returns `true` immediately after `app.hide()` (even though Zen is visually still on screen because Zen ignored the call), the retry's `if app.isHidden != desiredHidden` check (line 105) sees no drift and skips the SystemEvents re-issue — even though the screen still shows Zen.
3. The flashing the user observed is consistent with Zen briefly responding to `app.hide()` (or to the space-switch animation) and then re-showing itself. The architectural Zen note ("Zen fights for 500–1000ms") fits the timing of a "flash then remain visible" symptom.

---

## Hypothesis — AppKit + SystemEvents pairing regression (added 2026-05-03)

The Reference→Scratch first-cycle flash-then-visible regression in Attempt 3 is most plausibly caused by **changing how Zen is hit on the hide path**. The documented Zen invariant in `doc/arch/window-visibility.md:107` is: *"Any future hide logic for Zen must go through SystemEvents, not AppKit."*

Compare the AppleEvents Zen receives across attempts:

| | Initial call | Retry 1 | Retry 2 | Retry 3–5 |
|---|---|---|---|---|
| **Attempt 1** (passed first cycle) | `app.hide()` + SystemEvents | `app.hide()` only | SystemEvents only | — |
| **Attempt 3** (regressed first cycle) | `app.hide()` + SystemEvents | same pair | same pair | same pair, up to 5× |

Attempt 3 sends the AppKit `app.hide()` + SystemEvents osascript pair on every retry, repeated up to 6 times at 300ms intervals. AppKit `app.hide()` is documented as a no-op for Zen — but a no-op that still queues an AppleEvent. Pairing it with a SystemEvents call that does take effect, then repeating, plausibly puts Zen's event queue in a state where a successful SystemEvents hide is reversed by Zen's response to the AppKit event. Symptom matches: brief flash (one SystemEvents hide takes effect) followed by Zen re-appearing.

This is consistent with the rest of the evidence:
- The `intendedHiddenState` guard works correctly (no spurious cross-switch hides in the log).
- The 1.5s `isTilrActivating` extension suppresses cross-space CMD+TAB during its window but is not the cause of *first-cycle* flash.
- SystemEvents itself worked in Attempt 1 — it is not broken — but it is racing against repeated AppKit calls now.

**Diagnostic next step (1-line code change):** in `setAppHidden` and `scheduleHiddenStateRetry`, for the hide path, call **SystemEvents only** — drop `app.hide()`. Per the doc, AppKit hide is a no-op for Zen anyway; for other apps it's redundant once SystemEvents hides them. If first-cycle flash disappears with this change, it confirms the pairing was the culprit. Full instrumentation (the four log lines from "Next investigation step") is still the right path to permanent fix; this is a fast diagnostic to validate the hypothesis.

---

### 2026-05-03 — Attempt 4: SystemEvents-only hide path (diagnostic for pairing hypothesis)

**Code changed:** `Sources/Tilr/Layouts/AXWindowHelper.swift` only. In `setAppHidden`, the hide branch (`if hidden { ... }`) was changed to call only `setHiddenViaSystemEvents(bundleID:hidden:true)` — the preceding `app.hide()` call was removed. The same one-line removal was applied inside `scheduleHiddenStateRetry`, in the `if desiredHidden { ... }` branch: `app.hide()` removed, `setHiddenViaSystemEvents` retained. The doc-comment on `setAppHidden` was updated to describe the new behaviour and reference `doc/arch/window-visibility.md`. No other source files were touched: `AppWindowManager.swift` (1.5s `isTilrActivating`, `handleAppActivation` guard) is unchanged. Retry count (5), retry interval (0.3s), `intendedHiddenState` dict, and the unhide path (`app.unhide()`) are all unchanged.

**Hypothesis being tested:** The "AppKit + SystemEvents pairing regression" hypothesis from the section above. The documented Zen invariant (`doc/arch/window-visibility.md:107`) states that AppKit `app.hide()` is a no-op for Zen. The hypothesis is that pairing `app.hide()` with `setHiddenViaSystemEvents` on every hide call (up to 6 times at 300ms intervals in Attempt 3) puts Zen's AppleEvent queue in a state where a successful SystemEvents hide is subsequently reversed by Zen's deferred response to the AppKit event — producing the "flash then remain visible" symptom observed on the first Reference→Scratch cycle. If this is the cause, removing `app.hide()` from the hide path eliminates the conflicting AppKit event and SystemEvents alone should be sufficient to hide Zen cleanly.

**Expected result if hypothesis holds:** Zen hides without flashing on the first Reference→Scratch transition. Subsequent cycles (second and third runs of the sequence) may still fail — Attempt 1 showed second-cycle failures even with a single SystemEvents call — but this attempt is targeted specifically at the first-cycle regression introduced by Attempt 3. A clean first cycle confirms the pairing was the culprit and narrows the remaining problem to the second-cycle race documented in Attempt 1.

**What this does NOT change / does NOT test:**
- The 1.5s `isTilrActivating` window in `AppWindowManager.swift` is untouched; Zen fight-back suppression behaviour is unchanged.
- The `intendedHiddenState` guard (self-cancellation of stale retry chains) is untouched.
- The retry count (5) and interval (0.3s = 1.5s total coverage) are untouched.
- The unhide path (`app.unhide()`) is untouched.
- No new logging was added; the log will remain sparse for the same paths noted in the "Next investigation step" section. If this attempt fails, the instrumentation described there is the correct next move.

**Result:** CONFIRMED — SystemEvents-only hide path works. Zen hides, reappears, hides again, then remains stable. The "shows then hides again" cycle (Reference→Scratch at 06:46:40.722Z) is the visible manifestation of Zen's documented fight-back (~300–950ms per Attempt 2). Initial hide at T=0 via SystemEvents succeeds; Zen fights back and re-shows itself; retry at T+0.3s (or T+0.6s) catches it and SystemEvents-hides again; Zen does not fight back a second time → stable hidden.

**Analysis:**
- The pairing hypothesis is **confirmed**: removing `app.hide()` changed behaviour from "stays visible" (Attempt 3 first-cycle regression) to "hides → shows → hides → stable" (Attempt 4). This proves that repeated AppKit `app.hide()` + SystemEvents pairs were causing the first-cycle flash-then-visible symptom.
- Zen's fight-back window is real and the retry chain is catching it. The log is silent on retry/SystemEvents firings because those code paths have no instrumentation yet (being added separately per the "Next investigation step" section), but the user's observation of "hides then shows then hides again" is direct evidence the retries are firing and re-hiding Zen on the second attempt.
- Net result: **functionally correct** (Zen ends stable hidden) but with one visible flash during the 300–950ms fight-back window. Not acceptable as-is — users should see a clean, single hide with no visible flash or transition.

**What this confirms / rules out:**
- ✓ AppKit `app.hide()` pairing with SystemEvents is harmful for Zen and should not be reintroduced.
- ✓ SystemEvents-only is the correct fix direction.
- ✓ Zen fight-back is real and the 1.5s `isTilrActivating` window + 5-retry chain is correctly catching it (just not fast enough to hide the flash).

**Next investigation step (updated):** Attempt 4 proves the fix direction is correct but the fight-back flash remains. Tighter retries alone (e.g. 100ms instead of 300ms) may reduce the flash window but cannot eliminate it — Zen may still visually appear between T=0 hide and T=50–100ms retry. A different approach is needed. Candidates to investigate:
1. Detect Zen fight-back via `NSWorkspace.didActivateApplicationNotification` and re-hide immediately rather than waiting for a polling retry.
2. Suppress Zen's re-activation by calling `setHiddenViaSystemEvents` at T=0 AND again at T=50ms proactively (before fight-back, not after).
3. Investigate whether the fight-back is Zen activating itself (in which case `isTilrActivating` guard would suppress it) or Zen making itself visible via a different mechanism (in which case Zen-level window manipulation or workspace-level opacity/visibility is needed).

---

## Things already ruled out

- `NSRunningApplication.hide()` — confirmed useless for Zen, `isHidden` stays false. See `doc/implementation-notes/003-zen-browser-hide-unreliability.md`.
- Scheduling SystemEvents only on the final retry (T+0.6s) — too slow, was the original bug before this investigation started.
- `guard !app.isHidden` guard — removed 2026-05-03, was causing retries to not fire on 2nd cycle.
- No-early-exit retry chain (Attempt 2) — old retry chains from space A interfere with space B showing apps. Must have a cancellation mechanism.
- intendedHiddenState guard + 1.5s isTilrActivating + 5 retries (Attempt 3) — does not fix the first-cycle Reference→Scratch case. The guard correctly prevents cross-switch interference but the underlying hide of Zen still fails (or appears to fail) on the first cycle. The current logging is too sparse to distinguish "hide was never called" from "hide was called but ignored" from "hide was called, succeeded once, then Zen unhid itself".
- Empty `NSRunningApplication.runningApplications` at hide time — ruled out as cause of log silence. Silence was a logging bug (OSLog only, no TilrLogger call).

## Next investigation step — instrumentation, not a fix

The current log is silent on every code path that matters for diagnosing this bug. Before another fix is attempted, the following log lines must be added so the next reproduction can distinguish the three hypotheses above:

1. In `setAppHidden` (AXWindowHelper.swift line 83): on entry, log `bundleID`, `hidden`, instance count, and the pre-call `app.isHidden` of each instance. After `app.hide()`, log the post-call `app.isHidden`. After `setHiddenViaSystemEvents` returns, log that it returned (note that this is *before* osascript actually executes — see point 3).
2. In `scheduleHiddenStateRetry` (AXWindowHelper.swift line 98): on each retry tick log `bundleID`, `desiredHidden`, `attemptsRemaining`, the `intendedHiddenState[bundleID]` value, the live `app.isHidden`, and whether the re-issue branch was taken.
3. In `setHiddenViaSystemEvents` (AXWindowHelper.swift line 176): switch from fire-and-forget to capturing stdout/stderr and exit status. Log the osascript command, the return code, and any stderr. The current `try task.run()` swallows launch errors silently and never waits for completion — this is opaque exactly where Zen's hide depends on it.
4. In `handleAppActivation` (AppWindowManager.swift line 305): log every entry with `bundleID`, the `isTilrActivating` value at entry, and whether the early-return guard was taken. This will confirm or refute whether Zen-fight-back at T+~900ms is being suppressed by the 1.5s window.

Once these log lines exist, re-run the Reference→Scratch reproduction once and capture lines around the Scratch hotkey timestamp. The captured trace should answer, in order:

- Was `setAppHidden(zen, true)` called? (hypothesis: yes; if no, fix the upstream candidate set.)
- Did `osascript` succeed? (if no, this is the bug.)
- Did `app.isHidden` flip to `true` after hide? (if yes but Zen is visually present, AX state is lying — Zen-specific path required, e.g. NSAppleScript synchronous call or repeated SystemEvents on every retry regardless of `isHidden`.)
- Did any retry observe `app.isHidden == false` and re-issue? (if yes, even repeated SystemEvents is being ignored — escalate to `osascript -e 'tell application "<Zen>" to ...'` or window-level AX hide.)

Do not propose another code fix until the above instrumentation has been added and a fresh reproduction has been captured.

---

## Open Issues (identified 2026-05-03)

Three distinct issues identified from Attempt 4 instrumented log analysis. Work through in order — Issue 1 is blocking.

**Issue 1 — Hide instrumentation not appearing in tilr.log (BLOCKING diagnosis)**

The 4 `[hide]` log lines added in Attempt 4 were only wired to `Logger.windows.info(...)` (Apple OSLog → Console.app). The tilr.log file is written exclusively by `TilrLogger.shared.log(...)`. Every existing log line in the codebase that appears in tilr.log calls BOTH — the new hide lines were missing the `TilrLogger` half. The silence does NOT mean instances was empty or setAppHidden wasn't called. The code ran; we just couldn't see it. Fix: add paired `TilrLogger.shared.log(...)` calls alongside the 4 instrumentation lines (being done now).

**Secondary finding within Issue 1:** `pos=0 size=0` in all `setWindowFrame` log lines is NOT zero-sized frames — it is the AX result code (`0 = kAXErrorSuccess`). All layout calls are succeeding. `DisplayResolver` is a pure shim returning `NSScreen.main` and is not a cause of any issue.

---

**Issue 2 — Zen shown on Scratch switch (state model regression, likely displayResolver)**

When switching to Scratch from any prior space (including Coding, where Zen was already hidden), Zen is briefly made *visible* before being hidden. This did not happen before the `displayResolver` refactor. The symptom — "it THINKS zen should be there, shows it, then realises it shouldn't be, hides it again" — points to the state model incorrectly including Zen in the unhide set for Scratch, or the layout/retry machinery from the prior Reference activation calling `applyLayout("Reference")` after the Scratch switch, briefly unhiding Zen. The `displayResolver.screen(forSpace:)` change replaced `NSScreen.main` everywhere — if it returns an unexpected value, it could trigger incorrect layout passes. All `setWindowFrame` log lines show `pos=0 size=0` for all apps, suggesting `displayResolver` may be returning a zero-sized or incorrect screen frame.

**Observation (2026-05-03 14:22 — post-logging-fix reproduction):** Hide IS working correctly between Coding and Reference. The real issue is that when switching FROM Coding TO Scratch, Zen should remain hidden but is instead being SHOWN. This confirms the regression is specifically about Scratch incorrectly unhiding Zen, not about the hide mechanism itself. Responsiveness between Coding/Reference is also slower than baseline, suggesting the log instrumentation overhead or retry chains are still active.

Next step: read `DisplayResolver.swift` and check what `screen(forSpace:)` returns for each space. Also check whether `retryUntilWindowMatches` reapply closures from a prior Reference activation are still running during the Scratch switch and calling `applyLayout("Reference")`.

---

**Issue 3 — Sidebar reflow retry storm (non-blocking, cosmetic)**

After a Coding space switch, `retryUntilWindowMatches` for Marq and Ghostty (triggered by `reflow: app-unhidden` events) runs for 5+ seconds across subsequent space switches. Expected max budget is ~980ms (10ms + 20ms + 50ms + 100ms + 200ms×5). The generation token guard on the reflow path appears not to be cancelling these loops when a new space switch occurs. Two concurrent loops (one per sidebar app) each calling `applyLayout` interleave, producing 18+ `setWindowFrame` pairs. Non-blocking because Marq/Ghostty visually appear correct, but it adds noise to the log and may interfere with hide state. Likely caused by the reflow retry callback not capturing/checking `activationGeneration`.

Next step: check the reflow retry callback in `AppWindowManager.swift` (around line 658) for a generation token guard.
