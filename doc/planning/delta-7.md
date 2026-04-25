# Delta 7 — App layout

**Goal:** Per-space window positioning using sidebar and fill-screen layout modes, via the Accessibility API.

## Architecture

Control flow lives in `AppWindowManager` but delegates to small layout classes to keep the manager tidy:
- `Sources/Tilr/Layouts/SidebarLayout.swift`
- `Sources/Tilr/Layouts/FillScreenLayout.swift`
- Common protocol `LayoutStrategy` (avoid clash with `Config.Layout`) with one method: `func apply(space: SpaceDefinition, config: TilrConfig, screen: NSScreen) throws`
- `AppWindowManager.handleSpaceActivated` calls `hide/unhide` (existing Delta 6 behaviour), then picks the right strategy based on `space.layout?.type` and invokes it.

Accessibility API (`AXUIElement`) is used to position other apps' windows — `NSWindow` only controls your own app. This is a new permission requirement.

## First-run AX permission flow

- On app launch, call `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt: true`. This auto-triggers the system prompt (and opens System Settings → Privacy → Accessibility) if not already trusted.
- If permission is later denied at runtime, layout application fails gracefully — log a warning via `Logger.windows` and skip the positioning step. Hide/show (Delta 6) keeps working regardless.
- Don't block app startup on the prompt; it's asynchronous.

## Layout behaviours

**Sidebar:** `main` app takes `ratio` of the screen width (default 0.65 if unset) on the left. All other visible space apps stack in the remaining right column (same frame — they overlap). Preserves z-order — setting AX position/size attributes doesn't reorder windows. Verify empirically.

**Fill-screen:** every visible space app is sized to the full screen frame (apps overlap/stack). Z-order preserved as above.

**Screen selection:** `NSScreen.main` for MVP. Multi-display screen assignment via the `displays` config map is a future refinement.

## Dynamic resize (sidebar only)

When the user drags the edge of the main window or a sidebar window in a `sidebar`-layout space, the other windows re-tile to match. The new ratio is stored in a **session-only** in-memory dict (`[spaceName: Double]`) — not written to disk. Persistence across app restarts is a Delta 9 concern (state file).

**Mechanism:**
- Use the Accessibility API observer APIs (`AXObserverCreate`, `AXObserverAddNotification` with `kAXResizedNotification`).
- A new helper class `SidebarResizeObserver` (in `Sources/Tilr/Layouts/SidebarResizeObserver.swift`) owns:
  - The set of per-app `AXObserver` handles for the currently observed space.
  - The session ratio override dict `[String: Double]`.
  - A re-entrance flag to ignore observer callbacks that fire as a result of our own `setFrame` calls.
- `SidebarLayout` is promoted from `struct` to `final class` (it needs identity to own the observer instance). `FillScreenLayout` stays a `struct`.
- `AppWindowManager` holds a single long-lived `SidebarLayout` instance (instead of constructing a new one per dispatch) so its observer state survives across space switches.

**Lifecycle:**
- On `SidebarLayout.apply(...)`: the layout (a) tears down any existing observer set, (b) positions windows as today — reading the session override dict first, falling back to `config.layout.ratio`, falling back to `0.65`, (c) sets up fresh observers for the now-visible main + sidebar apps in this space.
- On space switch to a non-sidebar layout: observers are torn down (they shouldn't fire, but clean up to avoid leaks).

**Resize callback behaviour:**
- If the `ignoringResize` flag is true (set by our own `setFrame` — see below), return immediately.
- Identify which window fired: main, or one of the sidebars.
- If main was dragged: new ratio = `main.width / screen.width`. Clamp to `[0.1, 0.9]`. Store in session dict under `spaceName`. Re-tile the sidebar windows to the remaining right column.
- If a sidebar was dragged (user grabs the sidebar's left edge): new ratio = `sidebar.x / screen.width`. Clamp to `[0.1, 0.9]`. Store in session dict. Re-tile the main window and any other sidebar windows.
- Set `ignoringResize = true` immediately before the re-tile `setFrame` calls. Clear it ~500ms later on the main queue (`DispatchQueue.main.asyncAfter`) to swallow the echo events the OS generates from our own resize.

**Threading:**
- `AXObserver` callbacks fire on the main run loop. Everything stays `@MainActor`.
- The C callback bridges to Swift via `Unmanaged.passUnretained(self).toOpaque()` in the refcon, the standard AX pattern.

## Edge cases

- App not running → log and skip, don't crash.
- App running but no main window yet (just launched) → log and skip. No retry in this delta.
- `layout.main` set but not in `space.apps` → log and skip for cleanliness.
- No apps visible in the space → no-op, log nothing.
- Sidebar with zero non-main apps → main fills screen. With zero main but non-main visible → all non-main apps fill screen.

## Timing and implementation notes

- Start with zero delay after `unhide()`. If testing reveals a race, add a small dispatch delay; document the value and the reason.
- AX is finicky: `AXUIElementSetAttributeValue` can silently fail on sandboxed apps, full-screen apps, or apps that haven't granted their own AX cooperation. Log errors explicitly.
- `NSScreen.main` is the screen containing the focused window — may not match the `displays` config; this is fine for MVP and documented as a limitation.
- The config's `Layout.ratio` is a `Double?`; default 0.65 when nil. Fill-screen ignores ratio.
- Z-order preservation is an assumption, not a guarantee — call it out in Verification for empirical check.

## Out of scope (defer to later deltas/polish)

- Multi-display assignment.
- App-launch watcher that re-applies layout when a space app launches late.
- Stage Manager / Mission Control interactions.

**Subtasks:**
- [ ] AX permission check on launch via `AXIsProcessTrustedWithOptions` (in `AppDelegate` or a new helper). Log whether trusted.
- [ ] `Sources/Tilr/Layouts/LayoutStrategy.swift` — protocol (or whatever naming avoids clashing with `Config.Layout`).
- [ ] `Sources/Tilr/Layouts/SidebarLayout.swift` — implements sidebar positioning via AX.
- [ ] `Sources/Tilr/Layouts/FillScreenLayout.swift` — implements fill-screen positioning via AX.
- [ ] `AppWindowManager.handleSpaceActivated` — after hide/show, dispatch to the right strategy.
- [ ] Each layout strategy emits `Logger.windows.info("applying layout '<type>'")` at the start of `apply()`, before any positioning work, so logs have a clear header separating hide/show from layout application.
- [ ] Helper for AX window lookup: get the main/focused window of a running app and set frame via `kAXPositionAttribute` + `kAXSizeAttribute` (`CGPoint` and `CGSize` wrapped in `AXValue`).
- [ ] Graceful failures logged via `Logger.windows`.
- [ ] `project.yml` — add `Layouts/` dir to the Tilr target sources if xcodegen doesn't auto-include it (verify).
- [ ] Run `just gen` after adding files (reminder in the plan).
- [ ] `Sources/Tilr/Layouts/SidebarResizeObserver.swift` — owns per-app `AXObserver` set, session ratio override dict, re-entrance flag.
- [ ] Promote `SidebarLayout` from `struct` to `final class`; hold single long-lived instance in `AppWindowManager`.
- [ ] `SidebarLayout.apply` reads session ratio override (keyed by space name) before falling back to `config.layout.ratio` or `0.65`.
- [ ] Tear-down + re-setup of observers on each `apply`, scoped to the active space's visible apps.
- [ ] Re-entrance guard: `ignoringResize` flag set around our own `setFrame` calls, cleared ~500ms later.
- [ ] Clamp ratio to `[0.1, 0.9]`.

**Verification:**
1. Launch Ghostty + Marq, hit `cmd+opt+1` (Coding / sidebar layout): Ghostty left ~65% of screen, Marq right ~35%, both at full screen height.
2. Launch Zen Browser, hit `cmd+opt+2` (Reference / fill-screen layout): Zen fills full screen.
3. Switch back to `cmd+opt+1`: Ghostty/Marq re-tile (should not drift).
4. AX permission denied: switching spaces still hides/shows correctly; log shows a warning about missing AX trust; no crash.
5. `just logs` shows layout application line, e.g. `applied sidebar layout: main=Ghostty, ratio=0.65, sidebars=[Marq]`.
6. Windows retain their z-order after repositioning (foreground window stays foreground).
7. Drag the right edge of Ghostty (main) left: Marq (sidebar) resizes in real-time to maintain right-column fill; ratio persists while the app runs.
8. Drag the left edge of Marq (sidebar) right: Ghostty (main) resizes to match; other sidebars re-tile.
9. Drag main all the way right past the 0.9 clamp: resize stops at 90% — sidebar stays ≥10% wide.
10. Drag main all the way left past the 0.1 clamp: resize stops at 10%.
11. Switch to Reference (fill-screen) and back to Coding: the previously dragged ratio is preserved within the session.
12. Restart the app: ratio resets to config default (session-only — state-file persistence is Delta 9).

**Risk / notes:**
- AX is finicky: `AXUIElementSetAttributeValue` can silently fail on sandboxed apps, full-screen apps, or apps that haven't granted their own AX cooperation. Log errors explicitly.
- `NSScreen.main` is the screen containing the focused window — may not match the `displays` config; this is fine for MVP and documented as a limitation.
- The config's `Layout.ratio` is a `Double?`; default 0.65 when nil. Fill-screen ignores ratio.
- Z-order preservation is an assumption, not a guarantee — call it out in Verification for empirical check.
- `AXObserver` C callback must be bridged via refcon (`Unmanaged.passUnretained(self).toOpaque()`). Holding a strong reference to the observer on the Swift side is essential — dropping it silently stops the callbacks.
- 500ms re-entrance window is empirical (matches Lua). Tune if false-positive re-entrance bleeds in.
- Observer leaks are possible if teardown is skipped — always tear down before setting up, and on space-type change (sidebar → fill-screen).
