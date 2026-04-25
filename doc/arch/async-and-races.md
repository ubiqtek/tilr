# Async & Races: Patterns for Reliable Deferred Work

Tilr defers layout, focusing, and observer setup to work around AX timing issues. This doc covers the canonical patterns for guarding deferred work against race conditions and re-entrance.

## The problem

Layout is deferred ~100ms after hide/unhide to let AX become accessible. But Tilr is single-threaded (`@MainActor`), and subscribers to `SpaceService` events run synchronously, so multiple activations can queue up before the first one's deferred layout fires.

**Scenario:**
- T=0: User presses `cmd+opt+1` (Coding space)
- T=0: `handleSpaceActivated` queues layout at T+100ms, captures generation=1
- T=50ms: User presses `cmd+opt+2` (Reference space)
- T=50ms: `handleSpaceActivated` queues layout at T+150ms, captures generation=2
- T=100ms: First layout fires with gen=1, but `activationGeneration=2` — stale!
- T=150ms: Second layout fires with gen=2, correct.

Without guards, T=100ms would misposition Reference's windows.

## Pattern 1: Generation tokens

Use a counter to mark each async "batch" of work. Any deferred operation captures the current generation and guards before executing.

```swift
// In AppWindowManager
private var activationGeneration: UInt64 = 0

private func handleSpaceActivated(name: String) {
    // Increment at the START, before any work
    activationGeneration &+= 1
    let gen = activationGeneration
    
    // ... sync hide/show logic ...
    
    // Defer layout; guard captures gen and checks it
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self, self.activationGeneration == gen else {
            Logger.windows.info("space activation \(gen) stale (now \(self?.activationGeneration ?? 0)) — dropping queued layout")
            return
        }
        // ... apply layout ...
    }
}
```

**When to use:**
- Any deferred work tied to an activation or command
- Multiple rapid activations possible (hotkey mashing, script loops)
- Work order matters (later activation should override earlier)

**Implementation checklist:**
1. Declare `private var myGeneration: UInt64 = 0`
2. Increment at the top of the entry point (before sync logic, to capture ALL following async)
3. Capture: `let gen = myGeneration`
4. In every deferred block: `guard self.myGeneration == gen else { ...; return }`
5. Log the stale case with both gen values for debugging

**Code reference:** `AppWindowManager.swift:268, 380–384` (space activation tokens).

## Pattern 2: `isTilrActivating` guard (suppressing follow-focus)

When Tilr hides/shows/activates apps, it must suppress its own `didActivateApplicationNotification` observer to avoid re-entrance.

```swift
private var isTilrActivating = false
private var activationResetWorkItem: DispatchWorkItem?

private func handleSpaceActivated(name: String) {
    // SET GUARD AT START, before hide/show (macOS auto-promotes a new frontmost app)
    isTilrActivating = true
    activationResetWorkItem?.cancel()
    let resetWork = DispatchWorkItem { [weak self] in self?.isTilrActivating = false }
    activationResetWorkItem = resetWork
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: resetWork)
    
    // ... hide/show logic. If frontmost app is hidden, macOS promotes another app
    //     and fires didActivateApplicationNotification. But isTilrActivating is true,
    //     so handleAppActivation returns early. ✓
    
    // ... deferred activate() at T+100ms. Also guarded. ✓
}

private func handleAppActivation(notification: Notification) {
    guard !isTilrActivating else { return }  // Guard at entry point
    // ... cross-space and sidebar logic ...
}
```

**Critical detail:** Set the guard *before* hide/unhide, not after. When we hide the frontmost app, macOS immediately promotes a visible app to frontmost, firing the observer while we're still in `handleSpaceActivated`.

**Why 0.6s?**
- 100ms layout defer (waiting for AX readiness)
- 500ms settle window (app focus + AX responsiveness)
- Conservative upper bound; clears automatically

**When to use:**
- Any operation that hides/unhides apps and then activates apps
- Must suppress all `didActivateApplicationNotification` during the sequence

**Code reference:** `AppWindowManager.swift:267–279` (set at start), `AppWindowManager.swift:167–169` (guard check).

## Pattern 3: `.receive(on:)` is NOT free — the critical Combine gotcha

**CRITICAL WARNING:** Do NOT add `.receive(on: DispatchQueue.main)` to `SpaceService` event subscribers. It will silently reintroduce timing bugs.

**Why it matters:**

`AppWindowManager` subscribes to `service.onSpaceActivated`:

```swift
service.onSpaceActivated
    .sink { [weak self] event in
        self?.handleSpaceActivated(name: event.name)
    }
    .store(in: &cancellables)
```

Without `.receive(on:)`, the subscriber fires **synchronously** inside the `send()` call. This is correct — `handleSpaceActivated` runs on the same thread, same tick, same runloop as `switchToSpace`.

**The bug we had before fix:**

If someone adds `.receive(on: DispatchQueue.main)`:

```swift
service.onSpaceActivated
    .receive(on: DispatchQueue.main)  // WRONG — even from main, this queues async
    .sink { [weak self] event in
        self?.handleSpaceActivated(name: event.name)
    }
    .store(in: &cancellables)
```

Now the subscriber queues to the next runloop tick, even though it's already on main. In `AppWindowManager.moveCurrentApp`:

```swift
// BEFORE switchToSpace
activationGeneration &+= 1

service.switchToSpace(targetName, reason: .hotkey)
// At this point WITHOUT .receive(on:), handleSpaceActivated has ALREADY RUN
// synchronously and incremented generation. So "gen" will be newer.

let gen = activationGeneration
// "gen" now reflects handleSpaceActivated's increment. Correct.
```

With `.receive(on:)`, `handleSpaceActivated` hasn't run yet:

```swift
activationGeneration &+= 1

service.switchToSpace(targetName, reason: .hotkey)
// handleSpaceActivated will run later, in the next tick.

let gen = activationGeneration
// "gen" is still the OLD value! handleSpaceActivated's increment hasn't happened.
// When the layout deferred block runs, activationGeneration will have been
// incremented AGAIN (by the subsequent async), and the guard will see stale=true
// even though we meant for this gen to be current.
```

Result: Deferred layout drops with "stale" false positives.

**Why `SpaceService` is `@MainActor`:**

`SpaceService` is marked `@MainActor`, guaranteeing all calls and events fire on main. The hop to `.receive(on: DispatchQueue.main)` is redundant.

**Rule:** Never add `.receive(on:)` to `SpaceService` subscribers. If a subscriber needs to defer, it can call `DispatchQueue.main.asyncAfter` itself.

**Code reference:** `AppWindowManager.swift:37–41` (subscription, no `.receive(on:)`).

## Layout timing: 100ms vs 200ms

**Current setting:** 100ms defer between hide/unhide and layout apply.

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
    // ... apply layout ...
}
```

**Trade-off:**
- **100ms:** Snappier response, but risks "no content window" AX errors if apps are slow to settle post-hide.
- **200ms:** Safer, guarantees AX readiness, but feels sluggish on fast machines.

**When to increase back to 200ms:**
If logs show AX failures like:

```
AXError: AXUIElementCopyAttributeValue("AXMainWindow") failed: kAXErrorNoValue
"no content window for com.ghostty.dev"
```

Bump back to 0.2 and file a bug with the app's maintainers (many Electron/Qt apps are slow to settle post-unhide).

**Code reference:** `AppWindowManager.swift:380` (100ms defer in handleSpaceActivated).

## Retry loops & polling

Some operations need to poll for a condition (e.g., window frame actually changed post-AX-call). Use `retryUntilWindowMatches` with a short initial check + longer retries:

```swift
// In moveCurrentApp
retryUntilWindowMatches(bundleID: bundleID, targetSize: targetSize) { [weak self] in
    guard let self, self.activationGeneration == gen else { return }
    let currentConfig = self.configStore.current
    self.applyLayout(name: targetName, config: currentConfig, operation: operation)
}
```

**Schedule:** 10ms initial, then [20ms, 50ms, 100ms, 200ms×5] retries (cumulative ~980ms).

- Fast apps settle in 10–100ms
- Zen Browser fights for 500–1000ms (handles the 200ms×5 tail)
- Total budget still < worst-case app settle time

**Always guard retry blocks with generation tokens.** A superseding activation shouldn't re-apply layout for an old move.

**Code reference:** `AppWindowManager.swift:120–124` (moveCurrentApp retry guard).

## Debugging stale work

When you see "stale (now Y)" log lines, it means:
1. Rapid activations occurred (hotkey mash, script loop, or race condition)
2. An older activation's deferred work is still queued
3. The guard correctly suppressed it

**This is correct behavior.** Don't try to "fix" it by removing the guard — that would reintroduce mis-positioning.

**To reduce false positives:**
- Ensure your entry point increments the token FIRST, before any sync logic
- Ensure ALL deferred blocks in that flow capture the same generation
- Ensure the guard checks BEFORE any side effects

## Related docs

- [Space Switching](./space-switching.md) — Generation tokens in action
- [Cross-Space Switching (Delta 9)](./cross-space-switching.md) — `isTilrActivating` guard in action
- [Window Visibility](./window-visibility.md) — Why layout is deferred at all
- [macOS Windowing Primitives](./macos-windowing.md) — AX semantics that force deferred work

## Quick reference: Checklist for new async work

Before adding a new `DispatchQueue.main.asyncAfter` or `@escaping` block:

1. **Identify the entry point** — what command/event triggers this work?
2. **Does it need a generation token?** — Can the same entry point be called again before the async fires?
   - YES: Declare `private var myGeneration: UInt64`, increment at top, capture, guard in async.
   - NO: Can still add `.info()` logging with work ID for observability.
3. **Does it need an `isTilrActivating` guard?** — Does it hide/show apps?
   - YES: Set the guard at the START of the entry point, before hide/show.
   - NO: Skip it.
4. **Should the async work be logged?** — If it's user-visible (layout, popup, etc.):
   - Add a log line with generation or work ID so you can trace "stale (now Y)" in logs.
5. **Test rapid hotkey presses** — Verify guard log lines appear, verify final state is correct.

**Example:** Adding a new "fade in sidebar" animation:

```swift
private var animationGeneration: UInt64 = 0

private func startSidebarAnimation(spaceName: String) {
    animationGeneration &+= 1
    let gen = animationGeneration
    
    Logger.animation.info("starting sidebar fade for '\(spaceName)' (gen=\(gen))")
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self, self.animationGeneration == gen else {
            Logger.animation.info("sidebar animation \(gen) stale (now \(self?.animationGeneration ?? 0)) — skipping")
            return
        }
        // Apply animation
    }
}
```

Done.
