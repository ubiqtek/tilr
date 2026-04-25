# Cross-Space Switching (Delta 9)

**Goal:** When the user CMD-TABs to an app in a different space, automatically switch to that app's space and follow its context.

## Problem & motivation

In single-space window managers, CMD+TAB stays within the active space. In Tilr, apps are distributed across named spaces, so CMD+TAB should "follow focus" — if the user switches to an app that lives in a different space, Tilr automatically activates that space.

**Example:**
- Currently in Coding space (Ghostty + Marq).
- User presses CMD+TAB to Zen Browser (lives in Reference space).
- Tilr detects this, activates Reference, and shows Zen + other Reference apps.
- User is never surprised by seeing Zen full-screen when they expected Coding's layout.

## Architecture

### Event source

Use the existing `NSWorkspace.didActivateApplicationNotification` observer in `AppWindowManager`:

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { [weak self] notification in
    self?.handleAppActivation(notification:)
}
```

This observer fires on:
- CMD+TAB app switch
- Dock click
- Programmatic `NSRunningApplication.activate()`
- Focus change within a space

It does **not** fire when the user clicks a window of the already-frontmost app.

### Control flow

`handleAppActivation` is called on every frontmost-app change. **Cross-space switching is a new branch** that runs *before* in-space sidebar/fill-screen branches:

```
handleAppActivation(notification) {
    // Guard 1: ignore our own programmatic activations
    if isTilrActivating { return }
    
    // Guard 2: extract bundle ID
    guard let bundleID = app.bundleIdentifier else { return }
    
    // Guard 3: ignore Tilr itself
    guard bundleID != Bundle.main.bundleIdentifier else { return }
    
    // NEW: Cross-space branch
    if let targetSpace = spaceContaining(bundleID:),
       targetSpace != service.activeSpace {
        // Switch spaces and return (handleSpaceActivated will re-process)
        handleCrossSpaceActivation(bundleID, targetSpace)
        return
    }
    
    // Existing: in-space branches (fill-screen, sidebar)
    // Only run if the app belongs to the current space
    ...
}
```

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:170-191`.

## Implementation details

### App-to-space lookup

Helper method to find which space contains an app:

```swift
private func spaceContaining(bundleID: String) -> String? {
    configStore.current.spaces
        .first(where: { $0.value.apps.contains(bundleID) })?
        .key
}
```

Returns the first matching space name (data model assumes one home space per app). If the app is not configured in any space (Finder, System Settings, etc.), returns `nil` and no space switch occurs.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:153-157`.

### Source of truth: `service.activeSpace`

Always compare against `SpaceService.activeSpace`, the canonical active space:

```swift
guard let targetSpace = spaceContaining(bundleID: bundleID),
      targetSpace != service.activeSpace
else { return }
```

This is more authoritative than a local `currentSpaceName` mirror (which may lag briefly).

### Cross-space activation steps

1. **Log the event** (for observability):
   ```swift
   Logger.windows.info("follow-focus: '\(bundleID)' lives in '\(targetSpace)' — switching from '\(service.activeSpace ?? "none")'")
   ```

2. **Pre-register the app** (for fill-screen spaces):
   ```swift
   if targetConfig.spaces[targetSpace]?.layout?.type == .fillScreen {
       fillScreenLastApp[targetSpace] = bundleID
   }
   ```
   This ensures `handleSpaceActivated` includes the activated app in `visibleApps`. See [Fill-Screen App Tracking](#fill-screen-app-tracking) below.

3. **Set recursion guard**:
   ```swift
   isTilrActivating = true
   activationResetWorkItem?.cancel()
   let work = DispatchWorkItem { [weak self] in self?.isTilrActivating = false }
   activationResetWorkItem = work
   DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
   ```
   The flag must be set *before* calling `switchToSpace` (not after) to catch recursion on the same main-thread tick.

4. **Trigger the space switch**:
   ```swift
   service.switchToSpace(targetSpace, reason: .hotkey)
   ```
   Reuse `.hotkey` reason (not a new `.followFocus` reason) because downstream behavior is identical. Only introduce new reasons if different policy is needed (e.g., suppressing popup for follow-focus; not needed yet).

5. **Return early** so in-space branches don't run:
   ```swift
   return
   ```
   The subsequent `handleSpaceActivated` will re-process visibility and layout, making in-space logic redundant.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:170-191`.

### Recursion guard: `isTilrActivating` (critical timing fix)

**The bug:** When we call `service.switchToSpace(targetSpace)`, it eventually calls `handleSpaceActivated`, which calls `app.activate()` on the target app. This `activate()` call fires `didActivateApplicationNotification` again, which would normally trigger another cross-space check and infinite loop.

**The deeper bug (fixed 2026-04-25):** The guard was only set *inside* the 200ms-delayed asyncAfter block, just before the `activate()` call. But `handleSpaceActivated` also calls `hide()` on the previously-frontmost app. When we hide it, macOS auto-promotes the next visible app to frontmost. That promotion fires `didActivateApplicationNotification` *while `isTilrActivating` is still false*, so `handleAppActivation` runs the cross-space check, sees the promoted app is in a different space, and recursively switches back — causing flicker and lag.

**Fix:** Set `isTilrActivating = true` at the *START* of `handleSpaceActivated`, before any hide/show logic. Cover a 0.6s window (100ms layout delay + 500ms settle):

```swift
private func handleSpaceActivated(name: String) {
    activationGeneration &+= 1
    
    // SET THE GUARD FIRST — before hide/unhide logic
    isTilrActivating = true
    activationResetWorkItem?.cancel()
    let resetWork = DispatchWorkItem { [weak self] in self?.isTilrActivating = false }
    activationResetWorkItem = resetWork
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: resetWork)
    
    // NOW we're safe to hide/show — any app promotion won't trigger recursion
    // ... hide/show logic ...
    
    // Deferred activate() at T+100ms will also be guarded
}
```

**Why 0.6s?** The window covers:
- 100ms layout delay (see Space Switching) before we call `activate()`
- ~500ms app settle time after activate (conservative upper bound)
- Even if our scheduled reset doesn't fire (shouldn't happen), the flag naturally clears

**Code reference:** `AppWindowManager.swift:267–279` (guard set at start of `handleSpaceActivated`), `AppWindowManager.swift:167–169` (guard check in `handleAppActivation`).

**Lesson:** For any operation that hides/unhides and then activates, the guard should cover the entire sequence, not just the activate call. The hide operation itself can trigger re-entry.

## Fill-screen app tracking

In a fill-screen space, multiple apps may be configured, but only one is visible at a time. When the user CMD+TABs to an app in a fill-screen space:

1. `handleAppActivation` receives the notification and sees the app is in a different (fill-screen) space.
2. **Before** calling `switchToSpace`, we register the activated app as the fill-screen app:
   ```swift
   fillScreenLastApp[targetSpace] = bundleID
   ```
3. When `handleSpaceActivated` runs (as a result of the space switch), it reads `fillScreenLastApp` and computes `visibleApps = [bundleID]` (only the activated app).
4. Hide/show logic ensures only the activated app is visible; others are hidden.

**Why pre-register?** If we don't set `fillScreenLastApp` first, `handleSpaceActivated` would default to the previous session's focus or `layout.main`, showing the wrong app. Pre-registration ensures the app the user just cmd-tabbed to is the one that appears.

**Code reference:** `/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/AppWindowManager.swift:184-187`.

## Sidebar app framing

For in-space sidebar CMD+TAB (existing functionality, no change in Delta 9), the activated app is resized to its sidebar-slot frame and the previous sidebar-slot app is hidden:

```
User CMD+TABs to sidebar app in current space
  → handleAppActivation sees app is in currentSpace
  → sidebar branch: read targetFrame for app
  → call setFrame(app, targetFrame)
  → hide previousSidebarSlotApp
```

Cross-space CMD+TAB does **not** follow this path. Instead, it goes through the full space switch + `handleSpaceActivated` flow, which reapplies layout to all apps in the target space (including the activated app).

## Verification checklist

- [ ] Configure Coding (sidebar: Ghostty + Marq) and Reference (Zen at fill-screen).
- [ ] Activate Coding; CMD+TAB to Zen → Reference activates, Zen shown, Ghostty/Marq hidden, popup shows "Reference".
- [ ] CMD+TAB back to Ghostty → Coding activates symmetrically.
- [ ] CMD+TAB to Finder → no space change, no cross-space log line.
- [ ] CMD+TAB between Ghostty and Marq inside Coding → no space change; existing sidebar-slot framing runs (no regression).
- [ ] Logs show exactly one `follow-focus:` line per cross-space activation; no recursive activations.

## Related docs

- [Space Switching](./space-switching.md) — How space activation works
- [Window Visibility](./window-visibility.md) — Hide/show during space switch
- [Layout Strategies](./layout-strategies.md) — Sidebar and fill-screen positioning
- [macOS Windowing Primitives](./macos-windowing.md) — NSWorkspace and app activation

## Implementation status

- [x] Observer registration and callback
- [x] App-to-space lookup
- [x] Cross-space branch logic
- [x] Pre-register fill-screen app
- [x] Recursion guard
- [x] Logging
- [ ] Per-display follow-focus (Delta 10) — activate the space on the display hosting the app's window

## Notes for future work

**Multi-display (Delta 10+):** When Tilr supports multiple displays, follow-focus should activate the app's space on the display where the app's window is located, not necessarily the active display. This requires hooking `NSWindow` geometry to display assignment and is deferred.

**App-launch watcher:** If a space app launches after the space is inactive, layout isn't re-applied (but the app inherits the space's last layout frame when unhidden). Consider hooking `NSWorkspace.didLaunchApplicationNotification` to re-apply layout if the user is still in that space.
