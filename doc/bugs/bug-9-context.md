# BUG-9 Context Reference

## Problem Statement

When switching spaces in Tilr, Zen Browser (bundle ID `app.zen-browser.zen`) fails to hide reliably. In the sequence Reference → Scratch → Coding, Zen remains visible even though the space definition specifies it should be hidden. The symptom is intermittent and cyclical: the first Reference→Scratch cycle may pass or fail; if it passes, the second cycle (switching back to Reference then to Scratch again) reliably fails. This makes Zen's hide/show behaviour unpredictable and degrades the user experience of space separation.

## Key Findings from Prior Investigation

- **AppKit hide is a no-op for Zen:** `NSRunningApplication.hide()` is silently ignored by Zen. The `isHidden` property remains `false` even 500ms after the call. This is specific to Firefox-based browsers; other apps respond correctly.

- **SystemEvents is the only working mechanism:** `osascript -e 'tell application "System Events" to set visible of process "Zen" to false'` successfully hides Zen. After this call, `app.isHidden` correctly returns `true`.

- **AppKit + SystemEvents pairing causes regression:** When both `app.hide()` and `setHiddenViaSystemEvents` are called together on every hide attempt (as in Attempt 3), Zen exhibits a "flash and remain visible" symptom on the first cycle. The pairing likely puts Zen's AppleEvent queue in a conflicting state where a successful SystemEvents hide is reversed by Zen's deferred response to the AppKit event.

- **SystemEvents-only hide path works functionally:** Removing `app.hide()` and calling `setHiddenViaSystemEvents` alone results in correct functional hiding. However, Zen "fights back" by making itself visible again at 300–950ms post-hide, requiring a retry chain to catch and re-hide it. This is architecturally correct but produces a visible flash during the fight-back window.

- **Hide retry chain drops early apps:** Attempt 2 testing revealed that when retry chains span multiple space switches, old chains from a prior space activation (e.g., Reference) keep firing and clobber the hide state of the current space (e.g., Scratch). The solution is a cancellation guard (`intendedHiddenState` dict) that self-cancels stale retry chains if a subsequent space switch changes the intended hide state.

## Current Focus (Issue 2)

The primary functional issue is now secondary: when switching **to** Scratch space, Zen is briefly shown even though Scratch's space configuration explicitly hides Zen. This differs from the original bug (where Zen remained permanently hidden when it should have been shown). The regression appears to occur specifically on transitions to Scratch, suggesting the space's unhide set or the layout reapplication logic is incorrectly including Zen. Three hypotheses:

1. **DisplayResolver returning wrong screen** — `DisplayResolver.screen(forSpace:)` is currently a shim returning `NSScreen.main` for all spaces. If it returns a zero-sized or incorrect screen, layout reapply might trigger unexpected window visibility state changes.

2. **Stale fill-screen retry chains from prior space** — If the Reference space's `retryUntilWindowMatches` reapply closure is still running when Scratch switches, it might call `applyLayout("Reference")` mid-Scratch-switch, briefly unhiding Zen before the Scratch layout overwrites it.

3. **Scratch's space activation logic unhiding Zen** — The state model or space-switch logic might be incorrectly including Zen in the unhide set for Scratch, or calling `app.unhide()` on Zen as part of Reference's deactivation rather than Scratch's activation.

## Architecture to Read

- **`doc/arch/window-visibility.md:107`** — The Zen invariant and why SystemEvents is the only reliable hide mechanism for Zen Browser.

- **`doc/implementation-notes/003-zen-browser-hide-unreliability.md`** — Full investigation of why `NSRunningApplication.hide()` doesn't work for Zen and why the initial code had a 0.6s delay.

- **`doc/bugs/bug-9-investigation-log.md`** — Chronological attempt log with detailed hypothesis testing, code changes, and tradeoffs (Attempts 1–4).

## Logging Setup

Logs are written to `~/.local/share/tilr/tilr.log` with automatic rolling at 5 MB.

**Marker workflow (Claude's role):**
1. Before you start testing: Claude runs `tilr debug-marker "START: <test description>"` via CLI
2. You perform the UI actions or CLI tests (no marker needed from you)
3. After you finish: Claude runs `tilr debug-marker "END: <test description>"`
4. Claude reads and analyzes the bracketed log section

Key log categories:
- `[hide]` — hide/unhide calls and retry chain activity. Look for these lines to see whether `setAppHidden` was invoked, what `isHidden` read back, and whether retries fired.
- `[windows]` — high-level space activation logs showing which apps were shown/hidden per space.
- `[layout]` — window positioning via Accessibility Framework. Lines show `setWindowFrame` calls and their result codes (0 = success).
- `[verify]` — retry polling during layout application (e.g., `retryUntilWindowMatches`).

Most instrumentation was added in Attempt 4 (2026-05-03).

## Key Code Locations

- **`Sources/Tilr/Layouts/AXWindowHelper.swift`** — Lines 74–120:
  - `intendedHiddenState[bundleID]` dict tracks the most recent intended hide state per app
  - `setAppHidden(bundleID, hidden)` — Records intent, calls `setHiddenViaSystemEvents` for hide, schedules 5 retries at 0.3s intervals
  - `scheduleHiddenStateRetry` — Self-cancels if intent changes, re-issues SystemEvents if state drifted
  - `setHiddenViaSystemEvents` — Fires `osascript` via `Process()`, fire-and-forget (see Issue 1 in the investigation log)

- **`Sources/Shared/DisplayResolver.swift`** — Lines 7–19:
  - Currently a shim returning `NSScreen.main` for all spaces
  - Check its return value if Scratch switches show unexpected screen frames or layout ordering

- **`Sources/Tilr/AppWindowManager.swift`** — Lines 392–408:
  - `handleSpaceActivated` sets `isTilrActivating = true` and resets after 1.5s (Attempt 2 finding)
  - The 1.5s window suppresses `handleAppActivation` for any app focus event, protecting against Zen fight-back at ~950ms
  - Line 307: `handleAppActivation` early-return guard checking `isTilrActivating`

- **`Sources/Tilr/AppWindowManager.swift`** — Lines 328–345:
  - Hide/unhide loop in `handleSpaceActivated` calls `setAppHidden` for each app
  - Space configuration loads from `config.spaces[spaceName].apps`

## Remaining Unknowns

**Issue 1 — OSScript fire-and-forget opacity:** `setHiddenViaSystemEvents` calls `Process().run()` without waiting for completion or capturing return status. If the osascript launch fails or the command exits non-zero, no error is logged. Need to replace fire-and-forget with synchronous execution capturing stdout/stderr and return code to confirm the SystemEvents call actually succeeds.

**Issue 2 — Scratch show-then-hide regression:** Zen is briefly visible when switching to Scratch, then hidden. Root cause is likely in DisplayResolver, layout retry closure interference, or state model logic. Requires reading `DisplayResolver.swift` and the space activation logic in detail.

**Issue 3 — Sidebar reflow retry storm (cosmetic):** Marq and Ghostty retry chains run for 5+ seconds after Coding space switch, creating 18+ `setWindowFrame` pairs. Likely caused by reflow retry callback not capturing the activation generation token. Non-blocking but adds log noise.
