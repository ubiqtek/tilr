# Moving a window to another space — flow and known issues

Scope: what happens when the user presses `opt+shift+<key>` to move the focused
app to a different space, with a focus on window sizing after the move and the
asymmetry between the two directions (sidebar ↔ fill-screen).

Related files:
- `Sources/Tilr/AppWindowManager.swift` — `moveCurrentApp` and `handleSpaceActivated`
- `Sources/Tilr/Layouts/FillScreenLayout.swift` — fill-screen strategy
- `Sources/Tilr/Layouts/SidebarLayout.swift` — sidebar strategy
- `Sources/Tilr/Layouts/SidebarResizeObserver.swift` — ratio tracking + observer
- `Sources/Tilr/Layouts/AXWindowHelper.swift` — `setWindowFrame` via Accessibility API

Example setup (from `~/.config/tilr/config.yaml`):
- **Reference**: `fill-screen`, main = Zen, apps = [Zen, Chrome, Safari]
- **Coding**: `sidebar` (ratio 0.65), main = Ghostty, apps = [Ghostty, Marq]

---

## Status at a glance

| Direction | Target layout | Status | Primary symptom |
|-----------|--------------|--------|------------------|
| Coding → Reference | fill-screen | **working** after explicit retry added at T=350ms | (previously: sometimes wider than display) |
| Reference → Coding | sidebar | **broken** (asymmetric — no explicit retry) | Zen: correct X, wrong width (overflows right). Marq: first attempt fills screen; second attempt correct. |

---

## Timeline: Coding → Reference (fill-screen target, currently working)

**T = 0 ms** — `moveCurrentApp(toSpaceName: "Reference")`:
- Updates config in memory: Zen removed from Coding, added to Reference.
- Calls `service.switchToSpace("Reference", reason: .hotkey)`.

**T = 0 ms (sync)** — `handleSpaceActivated("Reference")`:
- Reference is fill-screen with `main: zen` → target = Zen.
- **Unhides** Zen. **Hides** Ghostty, Marq, and every other running regular-UI app.
- Schedules activation + layout apply for **T + 200 ms**.

**T = 200 ms** — scheduled block runs:
- `app.activate()` on Zen.
- `FillScreenLayout.apply(...)` iterates Reference's running apps (Zen, plus
  Chrome/Safari if running) and calls `setWindowFrame(bundleID, screen.frame)`
  for each. `screen` is `NSScreen.main ?? NSScreen.screens[0]`.

**T = 350 ms** — the deferred block inside `moveCurrentApp`:
- Gated on `targetLayoutType != .sidebar`.
- Calls `setWindowFrame(Zen, screen.frame)` again — **explicit retry**.
- Sends "moving Zen → Reference" notification.

So Zen's frame is set **twice**: once at T = 200 ms by `FillScreenLayout`,
again at T = 350 ms by the explicit retry. `setWindowFrame` itself issues
`Position → Size → Position` to correct drift from Sequoia tiling snap or
off-screen capping.

---

## Timeline: Reference → Coding (sidebar target, currently broken)

**T = 0 ms** — `moveCurrentApp(toSpaceName: "Coding")`:
- Config: Zen/Marq removed from Reference, inserted at index 0 of Coding.
- Calls `switchToSpace("Coding")`.

**T = 0 ms (sync)** — `handleSpaceActivated("Coding")`:
- Coding is sidebar → no single fill-screen target. visibleApps = Coding.apps.
- **Unhides** Zen (or Marq), Ghostty, and the other sidebar app.
- **Hides** everything else.
- `activateBundleID` = `layout.main` = Ghostty.
- Schedules activation + layout apply for **T + 200 ms**.

**T = 200 ms** — scheduled block:
- `app.activate()` on Ghostty.
- `SidebarLayout.apply(...)`:
  - Resolves `ratio` (override → `layout.ratio` → 0.65 default).
  - Computes `mainFrame` (left `ratio · width`, Ghostty) and `sidebarFrame`
    (right `(1 − ratio) · width`, everything else).
  - `setFrameAndSuppress(Ghostty, mainFrame)`.
  - For each sidebar bundleID (Zen, Marq): `setFrameAndSuppress(id, sidebarFrame)`.
  - Stores expected frames for snap-back detection.
  - Registers AX resize observers.

**T = 350 ms** — the deferred block inside `moveCurrentApp`:
- Gated on `targetLayoutType != .sidebar` → **branch NOT taken**.
- Only sends the "moving X → Coding" notification. **No explicit retry.**

This is the asymmetry: the sidebar branch gets the `SidebarLayout.apply` at
T = 200 ms and nothing else.

---

## Observed symptoms on Reference → Coding

### Zen (deterministic failure)

- **X position**: correct (at `ratio · screenWidth`, aligned to Ghostty's right edge).
- **Width**: wrong — stays at the previous full-screen width it had in Reference.
- **Result**: Zen's right edge lands at `ratio · sw + sw ≈ 1.65 · sw`, overflowing
  the display to the right by ~65 %.
- **Happens every time** the move is triggered from Reference.

### Marq (flaky failure)

- **First attempt**: Marq fills the entire screen — both position AND size wrong.
- **Second attempt**: works correctly (lands in the sidebar frame).

---

## Revised theory

The two symptoms rule out several candidates:

- Not a bug in `SidebarLayout.apply` itself — Zen's position is correct, so
  the sidebar frame is computed right and the position call is getting
  through. If the layout were broken, both apps would fail the same way.
- Not a min-width clamp — Marq's first-attempt failure is a full-screen frame,
  not a width clamped to a minimum. If AX were rejecting a too-small size
  request, Marq would get the correct position but a clamped width (same as
  Zen). The fact that Marq ends up at full-screen points to Marq's internal
  state overriding the AX call entirely.

**Most likely root cause: both apps have internal window-state that can
override the single AX call sequence we issue at T = 200 ms.**

- **Zen** (Firefox fork): accepts the position change (cheap) but refuses the
  shrink (expensive — triggers viewport reflow / Firefox's own
  size-remembering code). Deterministic because Zen's behaviour is consistent
  per call.
- **Marq** (Tauri/webview): still in its fill-screen state from Reference
  when the AX calls arrive. Its own window-management code wins the race on
  the first attempt; by the second attempt the state has settled and Marq
  accepts the placement.

Different failure modes, same class of root cause. The fix should be the
same: **give the app a second chance** after its internal state has settled.

---

## Proposed fix: symmetric explicit retry

Match the existing fill-screen pattern. In `moveCurrentApp`, after
`switchToSpace`, schedule an explicit retry at T = 350 ms regardless of
target layout type — fill-screen reapplies `screen.frame`, sidebar reapplies
the moved window's sidebar (or main) frame.

Pseudocode change in `AppWindowManager.moveCurrentApp`:

```
at T+350ms, for the moved bundleID:
  if target layout is fill-screen:
    setWindowFrame(moved, screen.frame)          # already exists
  else if target layout is sidebar:
    frame = sidebarLayout.frameFor(moved, space, screen)  # new
    setWindowFrame(moved, frame)
  send notification
```

`frameFor` resolves whether `moved` is the space's `layout.main` (→ mainFrame)
or a sidebar app (→ sidebarFrame), using the same ratio resolution chain as
`SidebarLayout.apply`.

Why this should work:
- Coding → Reference already proves the pattern: an explicit retry 150 ms
  after the layout apply is enough to override app-internal resistance.
- For Zen, the second `Position → Size → Position` sequence should win by the
  time Firefox's size-restoration has settled.
- For Marq, the retry covers the race on the first attempt — we don't need
  to rely on the user doing it twice.

Risks / things to watch:
- The retry could fight with the `SidebarResizeObserver` if the second frame
  set triggers an echo resize notification. `setFrameAndSuppress` suppresses
  for 600 ms, so a T = 350 ms retry will land inside the suppression window
  started at T = 200 ms — echo should be swallowed. (If we use plain
  `setWindowFrame` instead of `setFrameAndSuppress` we'd bypass the
  suppression bookkeeping and risk a spurious observer callback. Prefer
  `setFrameAndSuppress` — or extend suppression from inside the retry.)
- If the user has manually changed the ratio between T = 200 ms and T = 350 ms
  (extremely unlikely) the retry would use the updated ratio, which is
  actually correct behaviour.

---

## Diagnostic questions still open

- **Does the `set size failed` log line from `AXWindowHelper` appear** when
  moving Zen from Reference to Coding? If yes, AX itself is rejecting the
  shrink (min-width / constraint). If no, AX accepts it silently and Zen
  overrides later — which matches the theory above.
- **Single display or multiple?** Still relevant for any residual sizing
  weirdness after the retry fix lands.
