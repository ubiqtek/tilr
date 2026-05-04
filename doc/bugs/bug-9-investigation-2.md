# BUG-9 Investigation Log 2 — Methodical CLI Control Testing

**Context:** See [`bug-9-context.md`](bug-9-context.md) for problem statement, key findings, and architecture overview.

---

## Experiment 1: Direct CLI control of app hide/show

**Goal:** Determine if we have control over Zen and other apps using the CLI, verifying that the hide/show mechanism works independent of space switching.

**Approach:** Methodical testing using the CLI via socket delegation (same code path as space switching). This isolates the hide/show mechanism from the space-switching infrastructure.

**Test plan:**
- Run `tilr apps zen show` and observe behavior
- Run `tilr apps zen hide` and observe behavior
- Test additional apps to verify consistency (e.g., `tilr apps marq hide`, `tilr apps marq show`)
- Capture logs bracketed with debug markers for analysis

**CLI interface:** `tilr apps <name-or-bundle-id> <show|hide>`
- App name matching is case-insensitive contains (e.g., `zen` matches `Zen`)
- Exact bundle ID also works (e.g., `app.zen-browser.zen`)
- Commands are delegated via socket to the running app, using the same `setAppHidden()` code path as space switching
- Logs will show `[hide]` markers with retry chain details

## Results

**Zen show/hide (13:42:57–13:43:00):**
- Show worked: Zen flipped from hidden to visible in 29ms
- Hide: all 5 retries confirmed `desiredHidden=true isHidden=true` — stable
- No `SystemEvents:` line logged for Zen's hide, despite BUG-9 history showing AppKit hide is unreliable for Zen. Could be AppKit worked this time, or AX state reporting is stale
- No layout reflow triggered for Zen's visibility change

**Marq hide/show (13:43:07–13:43:08):**
- Hide and show issued 29ms apart; SystemEvents path takes ~280ms to land
- Brief race: retry loop saw wrong intermediate state before settling correctly
- Final state correct: `desiredHidden=false isHidden=false`
- Hide triggered a full layout reflow for the Coding space (Ghostty + Marq repositioned); Zen's hide did not

**Concerns raised:**
1. Absence of `SystemEvents:` for Zen is suspicious — visual confirmation needed that Zen actually hid
2. Zen's hide doesn't trigger layout reflow; Marq's does — either Zen isn't a managed layout window, or visibility observer isn't firing for it
3. No command coalescing: back-to-back hide/show faster than AppleScript can process causes a transient wrong state

[Raw log extract](logs/exp1-log-HST-a5567e.log)

### Addendum

The retry chain fires 5 times unconditionally even when Zen stays hidden throughout. All 5 retry checks in the experiment log reported `isHidden=true` — Zen never "fought back". This contradicts the assumption in earlier investigation notes that Zen re-shows itself 300–950ms after a successful hide. The retries are currently scheduled unconditionally; they only skip the re-hide action if state is already correct, but they always run to completion.

This raises two open questions:
1. Does Zen ever actually fight back, or was that assumption wrong?
2. Should the retry chain exit early once state has been stable for N consecutive checks?

These will be explored in Experiment 2.

A second run (log: `logs/hst-HST-6f1976.log`) caught a retry firing System Events a second time at remaining=5 (~312ms after the initial hide), with `isVisible=true` still reported. After the second System Events call, Zen was hidden by remaining=4. This confirms the retry chain is necessary — but it is unclear whether Zen actively "fights back" (hides then re-shows itself) or simply takes longer than 312ms for System Events to take effect. The current 300ms sampling interval cannot distinguish between these two cases. Resolving this is an open question for Experiment 2.

---

## Experiment 2: AppKit-first with osascript fallback (Zen focus)

**Focus:** Zen Browser only. Testing whether AppKit-first strategy works reliably for Zen.

**Goal:** Replace the osascript-only hide strategy with AppKit-first, falling back to osascript only if AppKit fails. Hypothesis: AppKit is faster and simpler for Zen, and we only need osascript as a fallback for edge cases.

**Terminology clarification:**
- **AppKit** = `NSRunningApplication.hide()/unhide()` — native macOS framework, controls app visibility. What Hammerspoon uses.
- **Accessibility Framework (AX)** = Separate API for window positioning (unrelated to hide/show).
- **System Events** = macOS automation service (osascript) — slower, fire-and-forget, but reliable for apps that don't respond to AppKit.

**Current asymmetry:** 
- `hideApp()` uses SystemEvents only (no AppKit)
- `showApp()` uses AppKit only (no SystemEvents)
- Yet Zen hides AND shows perfectly well

**Strategy:**
```
hideApp(bundleID):
  1. Try app.hide() (AppKit)
  2. If state check at T+300ms shows still visible → fallback to SystemEvents
  3. Retry loop continues for safety

showApp(bundleID):
  (unchanged, already uses app.unhide())
```

**Code changes:**
1. Modify `hideApp()` to call `app.hide()` first (before osascript)
2. Retry logic already handles the "still visible" case → naturally falls back to SystemEvents
3. Add logging to track which path was taken (AppKit vs SystemEvents)

**Test plan:**

Run the automated test script with Zen-only focus:
```bash
./ops/local/hide-show-test.sh zen
```

(Full script also supports `./ops/local/hide-show-test.sh` for both apps, or `./ops/local/hide-show-test.sh marq` for Marq only — but this experiment focuses on Zen.)

The script:
1. Generates a unique test ID (HST-XXXXXX)
2. Runs show/hide sequences with 6s settle time between commands
3. Brackets logs with debug markers for easy extraction
4. Automatically captures and displays the relevant log section

Manual steps if running without script:
- `tilr debug-marker "START: Experiment 2 hide test"`
- `tilr apps zen hide` and observe logs:
  - Do we see immediate success via AppKit, or state drift at T+300ms?
  - Does osascript fallback trigger, or does AppKit alone suffice?
- `tilr apps zen show` (unchanged, already uses AppKit)
- `tilr apps marq hide` to verify non-Zen apps work with new strategy
- `tilr debug-marker "END: Experiment 2 hide test"`
- Extract logs: `grep -A 100 "START: Experiment 2" ~/.local/share/tilr/tilr.log`

**Log analysis (what to look for):**

Look for these log patterns in the captured logs:

**AppKit success (no fallback):**
```
[hide] hideApp: 'app.zen-browser.zen' isVisible=true
[hide] AppKit: calling app.hide()
[hide] retry: 'app.zen-browser.zen' isVisible=false remaining=5
```

**AppKit drift with osascript fallback:**
```
[hide] hideApp: 'app.zen-browser.zen' isVisible=true
[hide] AppKit: calling app.hide()
[hide] retry: 'app.zen-browser.zen' isVisible=true remaining=5
[hide] osascript fallback: firing osascript (state drifted from AppKit)
[hide] retry: 'app.zen-browser.zen' isVisible=false remaining=4
```

**Key metrics to track:**
- How many retries see stable state (AppKit alone sufficient)?
- How many trigger osascript fallback (AppKit drifted)?
- Timing: does AppKit stabilize by retry 1 (300ms), or does it take longer?

**Success criteria:**
- Zen hides reliably within 300ms (AppKit alone)
- If state drifts, osascript fallback triggers and stabilizes it
- No regression on other apps
- Simpler mechanism: prefer native APIs, osascript only as fallback

---

## Results

**Test run:** `hst-HST-333acd.log`

```
2026-05-03T21:58:49.556Z [windows] [show] showApp: 'app.zen-browser.zen' isVisible=false
2026-05-03T21:58:49.556Z [windows] [show] AppKit: calling app.unhide()
2026-05-03T21:58:49.872Z [windows] [show] retry: 'app.zen-browser.zen' isVisible=true remaining=5
2026-05-03T21:58:50.188Z [windows] [show] retry: 'app.zen-browser.zen' isVisible=true remaining=4
2026-05-03T21:58:50.504Z [windows] [show] retry: 'app.zen-browser.zen' isVisible=true remaining=3
2026-05-03T21:58:50.620Z [windows] [hide] hideApp: 'app.zen-browser.zen' isVisible=true
2026-05-03T21:58:50.620Z [windows] [hide] AppKit: calling app.hide()
2026-05-03T21:58:50.933Z [windows] [hide] retry: 'app.zen-browser.zen' isVisible=false remaining=5
2026-05-03T21:58:51.250Z [windows] [hide] retry: 'app.zen-browser.zen' isVisible=false remaining=4
2026-05-03T21:58:51.567Z [windows] [hide] retry: 'app.zen-browser.zen' isVisible=false remaining=3
2026-05-03T21:58:51.883Z [windows] [hide] retry: 'app.zen-browser.zen' isVisible=false remaining=2
2026-05-03T21:58:52.196Z [windows] [hide] retry: 'app.zen-browser.zen' isVisible=false remaining=1
```

### Key Observations

**AppKit works perfectly for both hide and show.** No osascript fallback was triggered. Zen responded immediately and reliably to both `app.unhide()` and `app.hide()` calls.

**Show retries stop at remaining=3** because the user immediately called `hideApp()` while show retries were still running. This triggered the **intent self-cancel mechanism**: when the next show retry fired, it detected that `intendedVisibleState` had changed from true to false, and silently exited. This is correct behavior — the hide operation took over and the show retries gracefully yielded.

**Critical insight: Zen is NOT fighting back.** Under normal circumstances, Zen hides and shows perfectly. It does not "re-show itself" after being hidden, does not ignore AppKit calls, and does not require osascript as a primary mechanism. The previous investigation assumed Zen was "fighting" — that assumption was wrong.

### Implication for BUG-9

The window visibility issues observed in BUG-9 are **not a hide/show mechanism problem.** Zen hides and shows correctly. The issues must stem from **Tilr's own state management**:

- How space activation computes which apps should be visible
- How visibility intent is tracked and sequenced
- Potential race conditions between space switches and app focus changes
- State divergence between what Tilr intends and what the OS actually does

The retry loop and self-cancel mechanism we've built are working as designed, but they're addressing a symptom, not the root cause. Future investigation should focus on the space switching logic and state computation in `AppWindowManager`, not on hide/show reliability.

### Test Case 2: Marq hide → show (sidebar app)

**Test run:** `hst-HST-24bca8.log`

This run exercised a sidebar-managed app (Marq) instead of a main-pane app (Zen), which exposed a much noisier execution profile because Marq is part of the active layout for the `Coding` space.

**Hide phase (T=47.906s → T=48.972s, log lines 3–41):**
- `[hide] hideApp` fires, AppKit `app.hide()` is called immediately (line 4).
- 13ms later, `reflow: app-hidden` fires (line 5) — the visibility change has triggered the layout system.
- Lines 6–22 show the layout reflow doing its work: a cascade of `DisplayResolver` lookups and `setWindowFrame` calls trying to position both Ghostty (main) and Marq (sidebar). Because Marq has just been hidden, its content window is no longer AX-accessible, so we get a stream of `setWindowFrame: no content window for 'com.jimbarritt.marq'` errors. These are not failures of hide — they are the layout engine running against a window that legitimately no longer exists from AX's perspective.
- Hide retries fire at remaining=5, 4, 3 (lines 23, 32, 37), each correctly observing `isVisible=false`. Each retry also seems to retrigger a layout pass (lines 24–31, 33–36, 38–41).

**Show phase (T=48.973s → T=50.560s, log lines 42–91):**
- `[show] showApp` is called while hide retries are still pending (line 42, only ~125ms after the previous hide retry fired). AppKit `app.unhide()` is invoked (line 43) and `reflow: app-unhidden` follows immediately (line 44).
- Lines 45–49 show the first post-show reflow: now `setWindowFrame: 'com.jimbarritt.marq'` succeeds — the content window is back, and the layout engine can address it.
- **Line 50 — the key proof point:** `[hide] INTERRUPT: intent changed to Optional(true) (was false), cancelling retry chain`. The hide retry that was queued for ~T=49.15s detected that `intendedVisibleState` had flipped to true and self-cancelled. The same self-cancel mechanism we proved works for Zen also works for Marq.
- Show retries then fire at remaining=5, 4, 3, 2, 1 (lines 67, 76, 81, 86, 91), each observing `isVisible=true`. Layout reflows continue to fire alongside, all now successfully positioning Marq.

### Cross-Cutting Insight: Layout System Reactivity

The Marq run is dramatically noisier than the Zen run, but the noise is **not coming from the hide/show mechanism** — that part is identical to Zen and works flawlessly. The noise is coming from the **layout system reacting to visibility changes**:

- Each visibility change (`hide` or `unhide`) emits a `reflow: app-(hidden|unhidden)` event.
- Each reflow spawns ~3–5 `DisplayResolver` lookups and 2–4 `setWindowFrame` calls (one per managed window in the active layout).
- Hide and show retries each appear to trigger their own follow-on reflows, multiplying the work.
- Over ~2.6 seconds of hide+show on a single sidebar app, the log records **~14 DisplayResolver invocations and ~30+ setWindowFrame calls.**

For Zen, none of this fired because Zen is not part of the `Coding` space layout (it lives in a different space's main pane). For Marq, the entire layout for `Coding` (Ghostty + Marq) gets re-evaluated and re-applied multiple times per visibility transition.

### Implication for BUG-9 (Speculative)

BUG-9's symptoms — windows briefly appearing in wrong positions during space switches, perceived "flashing" or "thrashing" of windows, intermittent placement failures — fit this layout-cascade pattern much better than they fit a hide/show reliability problem:

- During a space switch, multiple apps' visibility flip in rapid succession. If each flip triggers an independent reflow, the layout engine is doing N separate cascading passes instead of one coalesced pass.
- The window pertaining to the app being hidden becomes AX-inaccessible mid-cascade, producing the "no content window" errors observed here. If a reflow happens to land on the wrong side of that transition, frames may be applied to stale window references or skipped entirely.
- The reactive nature of the layout system (visibility-change → reflow → setWindowFrame) means the *order* of hide/show operations during a space switch directly drives layout behavior, and any race between AppKit's visibility update and AX's window enumeration will surface as misplaced or unsized windows.

Concretely, this suggests two follow-up directions:

1. **Coalesce reflows during multi-app transitions.** A space switch should batch its visibility changes and run a single reflow at the end, not one reflow per app.
2. **Decouple reflow from per-app visibility events.** Reflow should be driven by an explicit "layout now" signal from `AppWindowManager`, not by NSWorkspace visibility notifications. The current reactive model means external visibility changes (user cmd-H, app self-hides, focus stealers) all trigger our layout engine — work we don't want and may actively race against.

Both of these align with the conclusion of Test Case 1 (Zen): the hide/show layer is fine. The interesting bugs live in the state-management and orchestration layer above it.

[Raw log extract](logs/hst-HST-24bca8.log)

---

## Experiment 3: Strip Back and Rework Layout Mechanism

**Goal:** Replace the reactive layout orchestration with an explicit, batched model that decouples reflow from per-app visibility events.

**Context:** See [`doc/arch/layout-flows.md`](../arch/layout-flows.md) for a concise architectural overview of why the current reactive model breaks during space switches (e.g., Ghostty not resizing when Marq is hidden).

**Key insight from Exp 2:** The hide/show mechanism is sound. The problem is layout orchestration. Currently, every visibility change triggers an immediate reflow, causing cascading layout passes with incomplete visibility state. Ghostty gets positioned multiple times based on partial information, resulting in incorrect or incomplete window frames.

**Target architecture:**
1. Batch all visibility changes during a space switch (collect all hide/show ops)
2. Issue all operations and wait for visibility state to stabilize
3. Run a single layout reflow with complete, final visibility state
4. Apply all window frames atomically

**Implementation notes:**
- Current architecture uses **generation tokens** (`activationGeneration` counter in `AppWindowManager`) to guard deferred layout against rapid hotkey presses. See [`doc/arch/async-and-races.md`](../arch/async-and-races.md) for details.
- Once layout is batched into a single explicit call instead of reactive per-app refloves, we may be able to simplify or eliminate generation token guards — the guard's job is to drop stale async layout operations, which becomes less critical if layout isn't reactive.
- Keep generation tokens in mind during refactoring as a simplification opportunity.

This experiment will rework `AppWindowManager.swift` space switching logic and the layout trigger system to implement this model.
