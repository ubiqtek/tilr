# Delta 6 — App visibility (AppWindowManager)

**Goal:** Activating a space hides apps not in that space and shows the apps that are. This makes Tilr actually functional — it's the first delta where a space switch has substantive behaviour beyond a popup.

**Out of scope:** Window positioning / layout (sidebar, fill-screen). That's a later delta. No app launching — if a configured app isn't running, skip it gracefully. No multi-display awareness — an app goes wherever macOS puts it.

**Architecture:** `AppWindowManager` is an output adaptor per `doc/arch/app-architecture.md`. It subscribes to `SpaceService.onSpaceActivated`, reads the `Space` definition from `ConfigStore`, and calls `NSRunningApplication` APIs to hide/show apps. It knows nothing about the popup, menu bar, or hotkey layers.

**Subtasks:**
- Create `Sources/Tilr/AppWindowManager.swift` — `@MainActor`, constructor takes `ConfigStore` and subscribes to `SpaceService.onSpaceActivated`.
- On activation event:
  - Look up the target `Space` in `ConfigStore.current.spaces` by name.
  - Compute the union of bundle IDs across ALL configured spaces (`allSpaceApps`).
  - Compute this space's app bundle IDs (`thisSpaceApps`).
  - For each `NSRunningApplication`: if its bundle ID is in `allSpaceApps` but NOT in `thisSpaceApps`, call `hide()`. If it's in `thisSpaceApps`, call `unhide()` (and optionally activate the `layout.main` app if present).
  - Apps whose bundle IDs aren't in any configured space are left alone.
- Add `Logger.windows` category. Log a single line per activation: `"applying space 'Coding': showing [...], hiding [...]"` (use `privacy: .public`).
- Wire into `AppDelegate` alongside `UserNotifier` and `MenuBarController`.

**Verification:**
- Launch Ghostty, Marq, Zen Browser, Chrome.
- `cmd+opt+1` (Coding): Ghostty + Marq visible; Zen + Chrome hidden.
- `cmd+opt+2` (Reference): Zen + Chrome + Safari visible; Ghostty + Marq hidden.
- Non-configured apps (e.g. Finder, whatever else is open) are untouched.
- `just logs` shows the `Logger.windows` activation line.

**Risk / notes:**
- Hiding/unhiding may require Accessibility permission — verify the app is in System Settings → Privacy → Accessibility. If not, document the prompt.
- Handle apps that aren't currently running — don't crash, just log and skip.
