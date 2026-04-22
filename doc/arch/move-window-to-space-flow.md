# Moving and resizing windows across spaces

Flow, the apps that resist, and the solution we converged on.

When a user moves the focused app to another space (via `opt+shift+<key>`) or drags a sidebar to resize, the system must apply new window frames and verify they actually stick. This doc covers the apply-and-verify pattern we settled on, the specific problem Zen Browser posed, and the lessons learned.

## Related files

- `Sources/Tilr/AppWindowManager.swift` — `moveCurrentApp`, `handleSpaceActivated`
- `Sources/Tilr/Layouts/FillScreenLayout.swift`
- `Sources/Tilr/Layouts/SidebarLayout.swift` — layout.apply + `frame(for:...)`
- `Sources/Tilr/Layouts/SidebarResizeObserver.swift` — drag observer + settle blocks
- `Sources/Tilr/Layouts/AXWindowHelper.swift` — `setWindowFrame`, `readWindowSize`, `retryUntilWindowMatches`
- `Sources/Tilr/Layouts/AXWindowFinder.swift` — `contentWindow(forApp:bundleID:)`

## Current flow: the exemplar (Zen from Reference to Coding)

User presses `opt+shift+C` to move Zen from Reference (fill-screen) to Coding (sidebar with Ghostty as main, 0.65 ratio).

- **T=0ms** — `moveCurrentApp("Coding")` updates config in memory, calls `service.switchToSpace("Coding", reason: .hotkey)`, schedules `retryUntilWindowMatches(bundleID: "zen.browser", targetSize: <sidebar frame size>)` to begin verifying at T+300ms.
- **T=0ms (sync)** — `handleSpaceActivated("Coding")` unhides target space apps, hides others, schedules layout apply for T+200ms.
- **T=200ms** — `SidebarLayout.apply` computes main and sidebar frames from screen geometry + ratio, calls `setFrameAndSuppress` (which wraps `setWindowFrame`) for main app and each sidebar app.
- **T=300ms** — first verify: reads Zen's width via `readWindowSize(bundleID:)`, compares to target width (within 2px tolerance).
  - If match: done (snappy path — most apps hit this).
  - If not: call `applyLayout(name: "Coding", ...)` again, wait 200ms, check again. Up to 4 total attempts (~1.1s worst case).
- **T=350ms** — popup notification fires (async, does not set frames).

## The apply-and-verify helper

`retryUntilWindowMatches(bundleID:targetSize:tolerance:firstCheckAfter:retryInterval:maxAttempts:reapply:)` in `AXWindowHelper.swift`:

- Defaults: tolerance = 2px, firstCheckAfter = 0.3s, retryInterval = 0.2s, maxAttempts = 4.
- Reads current window width via `readWindowSize(bundleID:)`.
- **Compares only width** — macOS menu bar (~34px) clamps height, so we request h=1117 but receive h=1083. Height is not under our control; width is.
- On match: logs `verify: '<bundleID>' matches on attempt <N> (w=<W>)`.
- On exhaustion: logs `verify: '<bundleID>' gave up after <N> attempts (want w=<TW>, got w=<W>)`.
- Used in three places: `moveCurrentApp` (verify moved window), main-drag `settleWorkItem`, sidebar-drag `settleWorkItem`.

## AX call ordering inside `setWindowFrame`

Current order: **Size → Position** (no trailing size call).

This mirrors Hammerspoon's `hs.window:setFrameWithWorkarounds` pattern (window.lua:322-350) in spirit: resize at current on-screen position first, then move to target. A trailing `setSize` was tried but removed — it causes Zen to snap x back to 0, undoing the position move.

## The content-window finder

`contentWindow(forApp:bundleID:)` in `AXWindowFinder.swift`:

- Fast path: check `kAXMainWindowAttribute`, return if subrole is `kAXStandardWindowSubrole`.
- Fallback: enumerate `kAXWindowsAttribute`, return first standard window.
- Logs which path matched + all subroles seen on fallback, for debugging apps with multiple AX windows (e.g. Marq after it added its own window management).

## What Zen Browser does that's weird

Zen has custom window management that fights AX calls:

- `setSize` on Zen: often accepted, but a subsequent `setPosition` call causes Zen to expand width back to its pre-move value.
- `setPosition` then `setSize`: Zen snaps x back to 0 during the size call.
- Neither order alone works.

**The fix: re-apply the layout until Zen accepts it.** After ~500–1000ms its internal state settles enough that a fresh layout apply succeeds. The 200ms primary debounce + 300ms first-check + 200ms retries is tuned for Zen's settle time. Most other apps (Marq, Ghostty) accept AX calls cleanly and hit the first-check match instantly.

## Things that did NOT work (and why)

- **Min-width constraint theory** — Zen landed at w=1150 instead of w=604. Looked like a browser min-width clamp. Ruled out: user confirmed Zen resizes smaller manually. Real cause was AX state-fight, not layout constraints.
- **Fixed 800ms delayed re-apply** — worked but laggy for Marq, which settles instantly.
- **Polling for size stability** (`whenWindowSettles`) — wrong signal. Zen's AX size is stable at the WRONG value during its fight window. Fired re-apply at ~111ms, far too early.
- **Symmetric T=350ms retry in `moveCurrentApp`** — immediate second `setWindowFrame` 150ms after the first interfered with Zen's post-layout settling. Removed.
- **Trailing `setSize` call in `setWindowFrame`** — caused Zen to snap x back to 0. Removed.

## Known imperfections and future work

- If Zen doesn't settle within 4 retry attempts (~1.1s total), we give up and log. Window may stay at wrong width. Rare in practice; raise `maxAttempts` if it becomes an issue.
- `maxAttempts` and delays are tuned for Zen on this machine. May need tuning for other stubborn apps (Chrome, Safari, Obsidian).
- Move-notification popup uses fixed 0.35s asyncAfter. Could be driven off verify completion but not worth the complexity.
- No multi-display support yet — `NSScreen.main ?? NSScreen.screens[0]` everywhere. Multi-display needs additional work in finder and setFrame paths.

## Debugging recipe

```sh
just logs-capture          # truncates .tilr-logs/session.log and streams
# in another terminal, or background it and do your moves
# inspect: grep "verify:" .tilr-logs/session.log
```

Key log lines to watch:

- `AX finder: '<id>' → fast-path | fallback | miss` — which AX window was selected.
- `AX: setting '<id>' to ...` + `AX: post-set frame for '<id>' ...` — requested vs actual frame.
- `verify: '<id>' matches on attempt N` or `gave up after N attempts` — placement outcome.
