import AppKit

/// Resolves which `NSScreen` should host a given space's layout.
///
/// Currently a shim — returns `NSScreen.main ?? NSScreen.screens[0]` for every space.
/// Future steps (delta-11 step 4) will consult `DisplayState.currentSpacePerDisplay`
/// and config `displays[id].defaultSpace` to route per-display.
public final class DisplayResolver {
    public init() {}

    public func screen(forSpace name: String) -> NSScreen {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        TilrLogger.shared.log(
            "DisplayResolver: space='\(name)' screen='\(screen.localizedName)' frame=\(screen.frame)",
            category: "layout"
        )
        return screen
    }
}
