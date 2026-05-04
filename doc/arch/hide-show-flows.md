# Hide and Show App Execution Flows

Complete execution flow diagrams and state tracking for `hideApp()` and `showApp()` operations in Tilr.

## Overview

Tilr controls app visibility through two primary functions:
- **`hideApp(bundleID)`** — Hide all running instances via System Events with retry logic
- **`showApp(bundleID)`** — Unhide all running instances via AppKit with retry logic

Both functions:
1. Record intent in `intendedVisibleState`
2. Perform the initial operation (SystemEvents for hide, AppKit for show)
3. Schedule up to 5 retries at 0.3s intervals
4. Log state at each step for debugging

**Key invariant:** Retries self-cancel if a concurrent space switch changes intent (e.g., hiding an app, then immediately switching spaces that shows it).

## Complete Call Chain: hideApp()

### Entry Points

`hideApp(bundleID)` is called from:
- **CommandHandler.swift:77** — CLI commands `apps-hide`
- **AppWindowManager.swift:351, 481, 648** — Space switch visibility logic, sidebar moves
- **SidebarLayout.swift:102, 136** — Sidebar layout operations
- **FillScreenLayout.swift:36** — Fill-screen layout moves

### Execution Flow

```
hideApp(bundleID: "com.example.app")
│
├─ [Line 85] intendedVisibleState[bundleID] = false
│            └─ Records intent to hide (for retry self-cancel)
│
├─ [Line 86-88] Fetch all running instances
│                let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
│                for app in instances {
│                    let isVisible = !app.isHidden
│
├─ [Line 89-90] Log initial state
│                Logger.windows.info("[hide] hideApp: '...' isVisible=...")
│                TilrLogger.shared.log("[hide] hideApp: '...' isVisible=...", category: "windows")
│
├─ [Line 91] Invoke System Events
│            setHiddenViaSystemEvents(bundleID: bundleID, hidden: true)
│            │
│            ├─ [Line 196-199] Fetch app name & log attempt
│            ├─ [Line 200-202] Build AppleScript: "tell application \"System Events\" to set visible of process \"<appName>\" to false"
│            ├─ [Line 204-211] Fire osascript process (fire-and-forget, errors swallowed)
│            │  └─ Asynchronous: OS processes hide request, AX windows become inaccessible
│            └─ Return immediately (no sync wait)
│
└─ [Line 92] Schedule retry chain
             scheduleHiddenStateRetry(bundleID: bundleID, desiredVisible: false, attemptsRemaining: 5)
             └─ (see "Retry Chain Logic" below)
```

### Timing and Logging

```
T=0ms:    [hide] hideApp: '...' isVisible=true
          └─ Initial call, app is still visible

T=0ms:    [hide] hiding using System Events: '...' appName='Zen Browser'
          └─ SystemEvents osascript spawned (async)

T=300ms:  [hide] retry: '...' isVisible=true remaining=5
          └─ First retry fires, state may still be drifting

T=300ms:  [hide] retry: firing SystemEvents for '...' (state drifted)
          └─ State check shows app still visible, re-invoke SystemEvents

T=600ms:  [hide] retry: '...' isVisible=false remaining=3
          └─ State stabilized, no re-invoke needed

T=900ms+: [hide] retry: '...' isVisible=false remaining=...
          └─ Subsequent retries see stable state, only log
```

## Complete Call Chain: showApp()

### Entry Points

`showApp(bundleID)` is called from:
- **CommandHandler.swift:79** — CLI command `apps-show`
- **AppWindowManager.swift:472** — Space switch visibility logic
- **SidebarLayout.swift:141** — Sidebar layout operations

### Execution Flow

```
showApp(bundleID: "com.example.app")
│
├─ [Line 101] intendedVisibleState[bundleID] = true
│             └─ Records intent to show (for retry self-cancel)
│
├─ [Line 102-104] Fetch all running instances and log
│                 let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
│                 for app in instances {
│                     let isVisible = !app.isHidden
│                     Logger.windows.info("[show] showApp: '...' isVisible=...")
│
├─ [Line 105-106] Log initial state
│                 Logger.windows.info("[show] showApp: '...' isVisible=...")
│                 TilrLogger.shared.log("[show] showApp: '...' isVisible=...", category: "windows")
│
├─ [Line 107] Invoke AppKit unhide
│            app.unhide()
│            └─ Synchronous call to macOS AppKit
│               (visibility change is asynchronous, but call returns immediately)
│               (AX windows become accessible ~200ms post-unhide)
│
└─ [Line 108] Schedule retry chain
             scheduleHiddenStateRetry(bundleID: bundleID, desiredVisible: true, attemptsRemaining: 5)
             └─ (see "Retry Chain Logic" below)
```

### Timing and Logging

```
T=0ms:    [show] showApp: '...' isVisible=false
          └─ Initial call, app is hidden

T=0ms:    app.unhide() invoked
          └─ AppKit call returns immediately

T=0-200ms: OS processes unhide, AX windows become accessible

T=300ms:  [show] retry: '...' isVisible=false remaining=5
          └─ First retry (state may still be drifting)

T=300ms:  [show] retry: firing SystemEvents for '...' (state drifted)
          └─ State check shows app still hidden, re-invoke unhide

T=600ms:  [show] retry: '...' isVisible=true remaining=3
          └─ State stabilized, no re-invoke needed

T=900ms+: [show] retry: '...' isVisible=true remaining=...
          └─ Subsequent retries see stable state, only log
```

## Retry Chain Logic: scheduleHiddenStateRetry()

The retry function is called recursively, scheduling async execution at 0.3s intervals. Each cycle:
1. Checks if intent has changed (self-cancel condition)
2. Reads current visibility state
3. If state doesn't match desired, re-invokes the operation
4. Logs the result
5. Schedules the next retry (if attempts remain)

### State Flow (Hide Retry)

```
scheduleHiddenStateRetry(bundleID, desiredVisible: false, attemptsRemaining: N)
│
├─ [Line 115] Schedule async task at T + 0.3s
│   DispatchQueue.main.asyncAfter(deadline: .now() + 0.3)
│
└─ At T + 0.3s:
   │
   ├─ [Line 116] Check self-cancel condition
   │   guard intendedVisibleState[bundleID] == desiredVisible else { return }
   │   │
   │   ├─ If intendedVisibleState[bundleID] == true:
   │   │   └─ Intent reversed (space switch changed intent), CANCEL silently
   │   │
   │   └─ If intendedVisibleState[bundleID] == false:
   │       └─ Intent still matches, PROCEED
   │
   ├─ [Line 117-118] Fetch app, get first instance
   │   let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
   │   guard let app = apps.first else { return }
   │
   ├─ [Line 119-121] Log current state
   │   tag = "[hide]"
   │   Logger.windows.info("[hide] retry: '...' isVisible=... remaining=N")
   │   TilrLogger.shared.log("[hide] retry: '...' isVisible=... remaining=N", category: "windows")
   │
   ├─ [Line 123-131] State check and re-invoke if needed
   │   if !app.isHidden != desiredVisible:        // Logic: if current != desired, re-invoke
   │       if !desiredVisible:                     // If trying to hide
   │           setHiddenViaSystemEvents(..., hidden: true)
   │           Logger.windows.info("[hide] retry: firing SystemEvents (state drifted)")
   │           TilrLogger.shared.log("[hide] retry: firing SystemEvents (state drifted)", ...)
   │       else:                                   // If trying to show
   │           app.unhide()
   │   else:
   │       // State matches desired, no re-invoke needed (only log)
   │
   └─ [Line 132] Schedule next retry (if attempts remain)
       scheduleHiddenStateRetry(bundleID, desiredVisible, attemptsRemaining - 1)
       └─ If attemptsRemaining <= 1: chain ends
```

### State Flow (Show Retry)

```
scheduleHiddenStateRetry(bundleID, desiredVisible: true, attemptsRemaining: N)
│
├─ [Line 115] Schedule async task at T + 0.3s
│
└─ At T + 0.3s:
   │
   ├─ [Line 116] Check self-cancel condition
   │   guard intendedVisibleState[bundleID] == desiredVisible else { return }
   │   └─ If intendedVisibleState[bundleID] == false:
   │       └─ Intent reversed (space switch hid the app), CANCEL silently
   │
   ├─ [Line 119-121] Log current state
   │   tag = "[show]"
   │   Logger.windows.info("[show] retry: '...' isVisible=... remaining=N")
   │
   ├─ [Line 123-131] State check and re-invoke
   │   if !app.isHidden != desiredVisible:        // Logic: if current != desired, re-invoke
   │       app.unhide()                           // Always use AppKit for show (line 129)
   │
   └─ [Line 132] Schedule next retry
       scheduleHiddenStateRetry(bundleID, desiredVisible: true, attemptsRemaining - 1)
```

### Retry Termination

```
Retry chain terminates when:
├─ attemptsRemaining == 0 (exhausted 5 cycles)
│  └─ Last scheduled task runs, decrements to 0, guard at line 114 returns
│
├─ intendedVisibleState[bundleID] != desiredVisible (intent reversed)
│  └─ Self-cancel triggered, chain exits silently
│
└─ App is no longer running
   └─ apps.first == nil at line 118, guard returns
```

### Example Retry Sequence (Show then Hide)

```
T=0ms:     showApp("com.example.app")
           intendedVisibleState["..."] = true
           app.unhide() called
           Schedule retry at T+300ms with attempts=5

T=300ms:   Retry 1: checks intendedVisibleState == true ✓
           App is still hidden
           Re-invoke app.unhide()
           Schedule retry at T+600ms with attempts=4

T=100ms:   (before retry 1) User switches spaces
           hideApp("com.example.app") called
           intendedVisibleState["..."] = false
           setHiddenViaSystemEvents(..., hidden: true)
           Schedule retry at T+400ms with attempts=5

T=300ms:   Show retry 1 fires
           Check: intendedVisibleState == true? NO
           └─ Intent changed to false, CANCEL SILENTLY

T=400ms:   Hide retry 1 fires
           Check: intendedVisibleState == false? YES
           App is hidden (or hidden by SystemEvents)
           No re-invoke needed
           Schedule retry at T+700ms with attempts=4

T=700ms-1.3s: Remaining hide retries (attempts 4→3→2)
             All see intendedVisibleState == false
             All see app is hidden
             No re-invokes, only logging
```

## State Tracking: intendedVisibleState

### Purpose

`intendedVisibleState: [String: Bool]` is a global actor-isolated dictionary that tracks the **most recent intent** for each app's visibility.

**Critical for retry self-cancellation:** When a space switch reverses visibility intent (e.g., hiding an app, then immediately switching spaces that shows it), subsequent retries from the original hide operation must self-cancel to avoid fighting the new intent.

### State Lifecycle

```
Initial state: intendedVisibleState["com.example.app"] = nil (no entry)

hideApp called:
  intendedVisibleState["com.example.app"] = false
  └─ Retries will proceed while this value == false

showApp called (before hide retries complete):
  intendedVisibleState["com.example.app"] = true
  └─ Old hide retries check intendedVisibleState == false, find true, self-cancel
  └─ New show retries proceed while this value == true

hideApp called again (while show retries running):
  intendedVisibleState["com.example.app"] = false
  └─ Old show retries check intendedVisibleState == true, find false, self-cancel
  └─ New hide retries proceed while this value == false
```

### Implementation Details

```swift
@MainActor var intendedVisibleState: [String: Bool] = [:]
```

- **Actor isolation:** `@MainActor` ensures thread-safe access (no locks needed)
- **Dictionary key:** Bundle ID string (e.g., "com.example.app")
- **Dictionary value:** Boolean (true = show intent, false = hide intent)
- **Scope:** Global, persists across all space switches and window operations
- **Cleanup:** Never explicitly cleared; entries overwritten on each intent change

### Self-Cancel Trigger

Every retry cycle checks:
```swift
guard intendedVisibleState[bundleID] == desiredVisible else { return }
```

If the check fails (intent has changed), the retry chain **exits silently** — no logging of cancellation, no state cleanup.

## Async Diagram: Call Ordering

```
Timeline of hideApp() followed by immediate showApp()
(space switch scenario):

Timeline (ms)  |  hideApp()              | showApp()              | Retries
─────────────────────────────────────────────────────────────────────────
T=0            |  intendedVisibleState   |
               |  = false                |
               |  log "[hide] hideApp"   |
               |  SystemEvents call      |
               |  Schedule retry@T+300   |
               |  (attempts=5)           |
               |                         |
T=100          |  [user space switch]    |
               |                         | intendedVisibleState
               |                         | = true
               |                         | log "[show] showApp"
               |                         | app.unhide()
               |                         | Schedule retry@T+400
               |                         | (attempts=5)
               |
T=300          |                         |
               |                         |                        | [hide] retry fires
               |                         |                        | Check intent==false?
               |                         |                        | NO (it's true)
               |                         |                        | CANCEL SILENTLY
               |
T=400          |                         |                        | [show] retry fires
               |                         |                        | Check intent==true?
               |                         |                        | YES
               |                         |                        | Log state, maybe re-invoke
               |                         |                        | Schedule retry@T+700
               |                         |                        | (attempts=4)
               |
T=700-1300     |                         |                        | [show] retries 3→2→1
               |                         |                        | All check intent==true
               |                         |                        | All log state
               |                         |                        | All schedule next
```

## Logging Progression: Complete Example

Detailed log sequence for a hide operation with state drift:

```
2026-05-03T10:15:42.123Z [windows] [hide] hideApp: 'app.zen-browser.zen' isVisible=true
  └─ Initial call, app was visible

2026-05-03T10:15:42.124Z [windows] [hide] hiding using System Events: 'app.zen-browser.zen' appName='Zen Browser'
  └─ SystemEvents osascript spawned

2026-05-03T10:15:42.423Z [windows] [hide] retry: 'app.zen-browser.zen' isVisible=true remaining=5
  └─ Retry 1 at T+300ms, state still shows app visible (drifting)

2026-05-03T10:15:42.424Z [windows] [hide] retry: firing SystemEvents for 'app.zen-browser.zen' (state drifted)
  └─ State mismatch detected, re-invoke SystemEvents

2026-05-03T10:15:42.723Z [windows] [hide] retry: 'app.zen-browser.zen' isVisible=false remaining=4
  └─ Retry 2 at T+600ms, state now shows app hidden (stabilized)

2026-05-03T10:15:43.023Z [windows] [hide] retry: 'app.zen-browser.zen' isVisible=false remaining=3
  └─ Retry 3 at T+900ms, state stable

2026-05-03T10:15:43.323Z [windows] [hide] retry: 'app.zen-browser.zen' isVisible=false remaining=2
  └─ Retry 4 at T+1200ms, state stable

2026-05-03T10:15:43.623Z [windows] [hide] retry: 'app.zen-browser.zen' isVisible=false remaining=1
  └─ Retry 5 at T+1500ms, state stable, final retry

[Retries end, chain terminates naturally]
```

Logging progression for a self-cancelled retry:

```
2026-05-03T10:15:40.100Z [windows] [hide] hideApp: 'com.jimbarritt.marq' isVisible=true
  └─ Hide initiated

2026-05-03T10:15:40.102Z [windows] [hide] hiding using System Events: 'com.jimbarritt.marq' appName='Marq'
  └─ SystemEvents invoked

2026-05-03T10:15:40.150Z [space] Switching to 'Coding' (hotkey)
  └─ User switches spaces before hide retries start

2026-05-03T10:15:40.200Z [windows] [show] showApp: 'com.jimbarritt.marq' isVisible=false
  └─ Space switch logic shows Marq (part of Coding space)

2026-05-03T10:15:40.202Z [windows] [show] showApp: 'com.jimbarritt.marq' isVisible=false
  └─ app.unhide() called

2026-05-03T10:15:40.400Z [windows] [hide] retry: 'com.jimbarritt.marq' isVisible=true remaining=5
  [NO MESSAGE FOR CANCEL]
  └─ Retry fires, but intendedVisibleState['com.jimbarritt.marq'] is now true
  └─ Guard check fails silently, chain EXITS

[Hide retry chain cancelled, show retries proceed normally]
```

## Special Cases and Invariants

### Zen Browser Hide Unreliability

Per `doc/implementation-notes/003-zen-browser-hide-unreliability.md`, Zen ignores `NSRunningApplication.hide()`. The hide logic compensates:

- **Only SystemEvents used:** Never pair `app.hide()` with SystemEvents (causes Zen to fight back)
- **Retries re-invoke SystemEvents:** If state drifts, retry cycles call `setHiddenViaSystemEvents` again
- **Multiple instances handled:** Loop through all `runningApplications(withBundleIdentifier:)` instances

```swift
// hideApp iterates all instances
for app in instances {
    // ... check, log, invoke, schedule ...
}
// But setHiddenViaSystemEvents targets by app name (localized), which affects all instances
```

### AX Inaccessibility Timing

When hiding, AX windows become inaccessible immediately. Per `doc/arch/window-visibility.md`:

- **Layout deferred 100–200ms:** After hide/unhide, layout operations are scheduled with delay
- **Pre-move resize:** Sidebar moves resize windows *before* hiding (to avoid AX inaccessibility)
- **Unhide readiness:** AX windows are accessible ~200ms post-unhide

Retry timing (0.3s intervals) is chosen to allow OS processing of hides and unhides without blocking layout.

### No Cleanup of Completed Intents

The `intendedVisibleState` dictionary accumulates entries forever (never explicitly cleared). This is acceptable because:

- Entries are small (String → Bool)
- Dictionary lookups are O(1)
- Old entries are overwritten by new intent changes
- Dictionary size is bounded by number of unique bundle IDs the user owns

If cleanup becomes necessary, a background task could periodically remove entries for non-running apps.

## Entry Points and Callers

### Via CLI

**CommandHandler.swift:70–84**
```swift
case "apps-hide", "apps-show":
    let hidden = request.cmd == "apps-hide"
    let postSend: (() -> Void)? = {
        DispatchQueue.main.async {
            if hidden {
                hideApp(bundleID: bundleID)
            } else {
                showApp(bundleID: bundleID)
            }
        }
    }
```

### Via Space Switching

**AppWindowManager.swift:471–482**
```swift
for bundleID in visibleApps {
    showApp(bundleID: bundleID)
}
for bundleID in hidingApps {
    suppressHideEvent(for: bundleID)
    hideApp(bundleID: bundleID)
}
```

### Via Sidebar Layout Operations

**SidebarLayout.swift:102, 136, 141**
```swift
hideApp(bundleID: bundleID)     // Resize sidebar-slot apps, hide
hideApp(bundleID: movedBundleID) // Hide departing app
showApp(bundleID: nextID)        // Promote next sidebar window
```

### Via Fill-Screen Layout Operations

**FillScreenLayout.swift:36**
```swift
hideApp(bundleID: bundleID)  // Hide all other space apps on move
```

## Files and Line References

| Operation | File | Line(s) |
|-----------|------|---------|
| `hideApp()` | `Sources/Tilr/Layouts/AXWindowHelper.swift` | 84–94 |
| `showApp()` | `Sources/Tilr/Layouts/AXWindowHelper.swift` | 100–110 |
| `scheduleHiddenStateRetry()` | `Sources/Tilr/Layouts/AXWindowHelper.swift` | 113–134 |
| `setHiddenViaSystemEvents()` | `Sources/Tilr/Layouts/AXWindowHelper.swift` | 195–212 |
| `intendedVisibleState` | `Sources/Tilr/Layouts/AXWindowHelper.swift` | 74 |
| Space switch visibility | `Sources/Tilr/AppWindowManager.swift` | 471–482 |
| Sidebar layout hide/show | `Sources/Tilr/Layouts/SidebarLayout.swift` | 102, 136, 141 |
| Fill-screen layout hide | `Sources/Tilr/Layouts/FillScreenLayout.swift` | 36 |
| CLI entry | `Sources/Tilr/CommandHandler.swift` | 77, 79 |

## Related Documentation

- **`doc/arch/window-visibility.md`** — Overview of hide/unhide model, timing invariants, AX inaccessibility
- **`doc/arch/space-switching.md`** — When visibility changes are triggered
- **`doc/arch/layout-strategies.md`** — Layout application after visibility changes
- **`doc/implementation-notes/003-zen-browser-hide-unreliability.md`** — Why Zen requires SystemEvents-only approach
- **`doc/arch/logging.md`** — Log categories and debugging workflow
