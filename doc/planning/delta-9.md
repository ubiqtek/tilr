# Delta 9 — Follow focus on CMD-TAB

**Goal:** when the user CMD-TABs (or otherwise activates) an app that lives
in a different space than the currently active one, automatically switch to
that app's space so the rest of its space's apps come with it.

- [x] Register an `NSWorkspace.didActivateApplicationNotification` observer
- [x] On activation: look up the app's bundle ID in `config.spaces`,
      find the space that contains it, call `SpaceService.activate(name:)`
- [x] Guard against recursion: while we're activating a space, ignore
      activation events triggered by our own `app.activate()` call (matches
      Hammerspoon's `activatingSpace` re-entrancy flag with a ~0.5s window)
- [x] Skip when the app belongs to the current active space (no-op)
- [x] Skip when the app belongs to no configured space
- [x] **Extended:** sidebar-specific CMD+TAB behaviour — when activating a sidebar-slot app, resize it into its frame and hide the previous slot app; reattaches drag observer
- [x] **Pending:** cross-space switching when activating an app in a different space — completed 2026-04-25

**Reference:** Hammerspoon `focusWatcher` in
`~/projects/dotfiles/home/hammerspoon/init.lua` (~line 652).

## Cross-space switching — implementation steps

The existing `NSWorkspace.didActivateApplicationNotification` observer in
`AppWindowManager.handleAppActivation` already captures CMD+TAB events and
applies sidebar-slot framing for in-space activations. The remaining work is
the **cross-space** branch: when the activated app belongs to a *different*
configured space, switch to that space.

1. **Reuse the existing observer, don't add a second one.** All cross-space
   logic goes inside `AppWindowManager.handleAppActivation(notification:)`.
   `NSWorkspace.didActivateApplicationNotification` is the correct API — it
   fires on every frontmost-app change (CMD+TAB, Dock click, programmatic
   `activate()`). Caveats: it fires for *our own* `app.activate()` calls too
   (handled by `isTilrActivating`); it does *not* fire when the user merely
   clicks a window of the already-frontmost app (fine — no space change
   needed); the notification is delivered on the main queue via the
   `Task { @MainActor in ... }` hop already in place.

2. **Add a cross-space branch before the in-space sidebar branch.** After the
   existing `isTilrActivating` guard and bundle-ID extraction, but *before*
   the fill-screen / sidebar-slot branches that assume the app belongs to
   `currentSpaceName`, evaluate cross-space membership. If we switch spaces
   we `return` — the subsequent `handleSpaceActivated` flow will re-process
   visibility and framing, so the in-space branch must not also run.

3. **App-to-space lookup helper.** Add a private method:
   ```swift
   private func spaceContaining(bundleID: String) -> String? {
       configStore.current.spaces
           .first(where: { $0.value.apps.contains(bundleID) })?
           .key
   }
   ```
   Iteration order over a Swift dictionary is unstable, but the first match
   is acceptable — Tilr's data model implicitly assumes one home space per
   app (matches Hammerspoon's `for spaceName in pairs(...)` loop). If we
   later need deterministic ordering, sort by space `id` before searching.

4. **Source of truth for the active space.** Use
   `service.activeSpace` (the `SpaceService` is the canonical owner — see
   `Sources/Tilr/SpaceService.swift`). `AppWindowManager.currentSpaceName`
   is a local mirror updated in `handleSpaceActivated`; both should agree,
   but `service.activeSpace` is the authoritative read. The check is a
   simple string equality:
   ```swift
   guard let targetSpace = spaceContaining(bundleID: bundleID),
         targetSpace != service.activeSpace
   else { return }
   ```

5. **Trigger the switch via `SpaceService`.** Call
   `service.switchToSpace(targetSpace, reason: .hotkey)`. We deliberately
   reuse `.hotkey` rather than introduce a new `.followFocus` reason — the
   downstream show/hide/layout behaviour is identical and adding a reason
   forces every `switch reason` site to add a case for no benefit. (If we
   later want to suppress the popup specifically for follow-focus, *that*
   is the moment to add the reason.)

6. **Recursion guard — extend `isTilrActivating`.** The existing
   `isTilrActivating` flag plus its 0.5s `activationResetWorkItem` already
   covers the loop: `switchToSpace` triggers `handleSpaceActivated`, which
   sets the flag *before* calling `app.activate()` on the new front app.
   That activation fires `didActivateApplicationNotification`, our handler
   sees the flag set, and returns early. Set the flag immediately *before*
   calling `service.switchToSpace` and schedule the same 0.5s reset:
   ```swift
   isTilrActivating = true
   activationResetWorkItem?.cancel()
   let work = DispatchWorkItem { [weak self] in self?.isTilrActivating = false }
   activationResetWorkItem = work
   DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
   service.switchToSpace(targetSpace, reason: .hotkey)
   ```
   Setting the flag *before* `switchToSpace` (not after) closes the race
   where `handleSpaceActivated` runs synchronously on the same tick.

7. **Edge cases handled by the guards in steps 3–4.**
   - *App not in any configured space (Finder, System Settings, etc.):*
     `spaceContaining` returns `nil` → `guard` returns early. No log noise.
   - *App in current active space:* `targetSpace == service.activeSpace` →
     `guard` returns early; existing in-space sidebar/fill-screen branches
     run as today.
   - *Same app in multiple spaces:* first match wins (step 3). Document as
     a known limitation; `tilr spaces config add-app` already prevents
     accidental duplicates in normal use.
   - *Tilr itself activated:* already filtered by the existing
     `Bundle.main.bundleIdentifier` check pattern used in `moveCurrentApp`;
     add the same exclusion here for safety:
     `guard bundleID != Bundle.main.bundleIdentifier else { return }`.

8. **Logging.** One `Logger.windows.info` line per cross-space switch,
   mirroring the Hammerspoon `log.i("focus: ... → activating ...")` line:
   ```swift
   Logger.windows.info("follow-focus: '\(bundleID, privacy: .public)' lives in '\(targetSpace, privacy: .public)' — switching from '\(service.activeSpace ?? "none", privacy: .public)'")
   ```
   Also useful for `verify:` lines in tests: a single `follow-focus:` token
   makes the event greppable in `just logs-capture` output.

9. **Verification.**
   - Configure Coding (sidebar: Ghostty + Marq) and Reference (Zen).
   - Activate Coding; CMD+TAB to Zen → Reference activates, Zen shown,
     Ghostty/Marq hidden, popup fires `↺ Reference`.
   - CMD+TAB back to Ghostty → Coding re-activates symmetrically.
   - CMD+TAB to Finder while in Coding → no space change, no log line.
   - CMD+TAB between Ghostty and Marq inside Coding → no space change;
     existing sidebar-slot framing runs as today (no regression).
   - `just logs-capture` shows exactly one `follow-focus:` line per
     cross-space activation; no recursive activations.

10. **Out of scope (defer).** Per-display follow-focus (multi-display:
    activate the space on the *display* hosting that app's window) lands
    with Delta 10. The single-display assumption keeps step 4's
    `service.activeSpace` check correct for now.

---

## What we learned

**Race conditions discovered and fixed (2026-04-25):**

1. **Generation-token pattern** — AppWindowManager now maintains a UInt64 generation counter (incremented at the top of `handleSpaceActivated`). All asyncAfter blocks capture the current generation; if it has changed by the time the block fires, the block returns early with a log line. Eliminates stale layout work from rapid space switches.

2. **`isTilrActivating` timing fix** — was set inside the 200ms-delayed asyncAfter (too late). When hiding the previously-frontmost app, macOS auto-promotes another visible app, firing our `handleAppActivation` with the guard still false, causing recursive space switches. Fix: set the flag at the very START of `handleSpaceActivated`, with a 0.6s reset.

3. **`.receive(on:)` removal** — SpaceService's onSpaceActivated subscriber had a `.receive(on:)` hop to the main queue. This queued `handleSpaceActivated` to the next runloop tick, breaking the generation-token capture order in `moveCurrentApp`. Fix: run the handler synchronously within the subscription's `send()` call.

See `doc/arch/async-and-races.md` for the canonical reference and implementation detail.
