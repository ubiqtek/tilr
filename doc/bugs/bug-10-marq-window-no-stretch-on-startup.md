# BUG-10 Context Reference

## Problem Statement

When Tilr starts and performs initial layout for the Coding space, if the Marq window was previously narrower than the intended layout width, the window does not expand to fill the screen. The window position is correct, but the width remains constrained to the previous dimensions instead of stretching to match the configured layout.

## Reproduction Steps

1. Open Marq and manually resize it to be narrower than the full screen width
2. Close Tilr (if running)
3. Restart Tilr
4. Observe: Tilr activates the Coding space and applies the layout
5. Check Marq window: position is correct, but width is too narrow (hasn't expanded to fill)

## Status

Deferred — not yet investigated. This is a "capture and come back to later" bug.

## Next Steps

When investigating, check:
- Whether Marq respects frame-setting via Accessibility Framework
- If there's a timing issue (window laid out before Marq is fully ready)
- Whether this is specific to Marq or affects other apps
