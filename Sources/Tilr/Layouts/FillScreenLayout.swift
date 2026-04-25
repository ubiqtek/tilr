import AppKit
import OSLog

struct FillScreenLayout: LayoutStrategy {

    func apply(name: String, space: SpaceDefinition, config: TilrConfig, screen: NSScreen, operation: OperationType) {
        TilrLogger.shared.log("fill-screen apply: AX trusted=\(AXIsProcessTrusted()) operation=\(operation)", category: "layout")
        guard AXIsProcessTrusted() else {
            Logger.layout.info("layout 'fill-screen': AX permission not granted — skipping positioning")
            return
        }
        let sf = screen.frame

        switch operation {
        case .spaceSwitch:
            // Space-switch: frame only the visible fill-screen target (not hidden apps).
            let visibleApps = space.apps.filter { bundleID in
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .contains { !$0.isHidden }
            }
            TilrLogger.shared.log("fill-screen spaceSwitch: visibleApps=\(visibleApps) in space \(name) (space.apps=\(space.apps))", category: "layout")
            guard !visibleApps.isEmpty else { return }

            for bundleID in visibleApps {
                let result = setWindowFrame(bundleID: bundleID, frame: sf)
                TilrLogger.shared.log("fill-screen setWindowFrame '\(bundleID)' result=\(result)", category: "layout")
            }

            let names = visibleApps.map { $0.components(separatedBy: ".").last ?? $0 }.joined(separator: ", ")
            Logger.layout.info("applied fill-screen layout (switch): [\(names, privacy: .public)] frame x=\(sf.origin.x) y=\(sf.origin.y) w=\(sf.width) h=\(sf.height)")

        case .windowMove(let movedBundleID, _, _):
            // Move-into: hide all other space apps, apply fill-screen frame only to moved app.
            let others = space.apps.filter { $0 != movedBundleID }
            for bundleID in others {
                setAppHidden(bundleID: bundleID, hidden: true)
                Logger.layout.info("fill-screen move: hiding competitor '\(bundleID, privacy: .public)'")
            }

            let movedName = movedBundleID.components(separatedBy: ".").last ?? movedBundleID
            setWindowFrame(bundleID: movedBundleID, frame: sf)
            Logger.layout.info("applied fill-screen layout (move): \(movedName, privacy: .public) frame x=\(sf.origin.x) y=\(sf.origin.y) w=\(sf.width) h=\(sf.height)")
        }
    }
}
