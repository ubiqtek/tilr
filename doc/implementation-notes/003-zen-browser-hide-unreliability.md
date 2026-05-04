# Zen Browser hide unreliability — why NSRunningApplication.hide() doesn't work

## The bug (BUG-9)

When switching spaces in Tilr, Zen Browser (bundle ID `app.zen-browser.zen`) would remain visible on screen for ~0.6 seconds, sometimes longer, after a space switch that should hide it. The sequence Reference → Scratch → Coding was reliably reproducible: Zen would stay visible in Scratch.

## Investigation

We used `tilr debug-marker` to bracket the reproduction, then read the log. The logs confirmed `[windows] applying space 'Scratch': showing [1Password], hiding [Zen, ...]` — Tilr WAS issuing the hide. But Zen stayed visible.

We tested the hide mechanisms directly from Swift:

```swift
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "app.zen-browser.zen").first!
app.hide()
Thread.sleep(forTimeInterval: 0.5)
print(app.isHidden)  // → false !!
```

`NSRunningApplication.hide()` is **completely ignored** by Zen Browser. `isHidden` stays `false` even 500ms after the call.

We also tested `NSRunningApplication.unhide()` — also doesn't work once SystemEvents has taken over the hidden state.

SystemEvents DOES work:

```
osascript -e 'tell application "System Events" to set visible of process "Zen" to false'
```

After this call, `app.isHidden` correctly returns `true`.

## Why the old code had a 0.6s delay

`setAppHidden` in `AXWindowHelper.swift` calls `app.hide()` first, then schedules `scheduleHiddenStateRetry` with 2 attempts at 0.3s intervals. Only on the final attempt does it call `setHiddenViaSystemEvents` (the osascript path). So Zen stayed visible for:

- T+0.0s: `app.hide()` — ignored by Zen
- T+0.3s: retry 1 — `app.hide()` again — ignored
- T+0.6s: retry 2 (final) — `setHiddenViaSystemEvents` — WORKS

## The fix

Call `setHiddenViaSystemEvents` immediately alongside `app.hide()` in `setAppHidden`. Once SystemEvents hides Zen, `isHidden` correctly returns `true`, so the retry at +0.3s sees a match and exits early. No more 0.6s window.

```swift
if hidden {
    app.hide()
    setHiddenViaSystemEvents(bundleID: bundleID, hidden: true)  // immediate belt-and-suspenders
} else {
    app.unhide()
}
```

## Why activate() works for unhide

`handleSpaceActivated` calls `app.activate(options: [])` in the space switch flow. `activate()` implicitly shows a hidden app — this is what actually brings Zen back when switching to Reference, not `app.unhide()`.

## Generalisation

Zen Browser (Firefox/Gecko architecture) doesn't respond to AppKit hide/unhide events. Any future work hiding apps should assume SystemEvents is the reliable path, with `app.hide()`/`unhide()` as a best-effort first attempt. The retry mechanism in `scheduleHiddenStateRetry` remains as a safety net for other apps.
