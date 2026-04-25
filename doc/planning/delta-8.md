# Delta 8 — Moving apps to a space

**Goal:** Hotkey (opt+shift+id) moves the currently focused app from its current space into the target space, at runtime. In-memory only — no config write.

**Subtasks:**
- [x] Bind `moveAppToSpace` modifier + space id hotkeys (mirrors switch hotkeys)
- [x] On trigger: identify frontmost app's bundle ID
- [x] Remove bundle ID from its current space's `apps` list (in-memory)
- [x] Add bundle ID to the target space's `apps` list (in-memory)
- [x] Log the move; no config save

**Verification:**
- [x] Focused app moves to target space when opt+shift+id pressed
- [x] App is hidden/shown correctly on next space switch
- [x] Original space no longer manages the moved app

**Notes:**

**Follow-up tasks:**
- **FillScreenLayout cleanup:** The `.spaceSwitch` case frames ALL running apps in the space, not just the visible one. Should only frame `visibleApps` (the single fill-screen target). Hidden apps like Chrome get silent AX frames applied unnecessarily.
- **Try lowering retryUntilWindowMatches delay for fill-screen:** Currently `firstCheckAfter: 0.3` (300ms). Try 100ms to make the resize feel snappier. The window may settle faster than 300ms in most cases.
