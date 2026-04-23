import AppKit
import OSLog

struct FillScreenLayout: LayoutStrategy {

    func apply(name: String, space: SpaceDefinition, config: TilrConfig, screen: NSScreen, operation: OperationType) {
        guard AXIsProcessTrusted() else {
            Logger.layout.info("layout 'fill-screen': AX permission not granted — skipping positioning")
            return
        }
        let sf = screen.frame

        switch operation {
        case .spaceSwitch:
            // Normal space-switch: frame all running apps in the space.
            let runningApps = space.apps.filter { bundleID in
                !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            }
            guard !runningApps.isEmpty else { return }

            for bundleID in runningApps {
                setWindowFrame(bundleID: bundleID, frame: sf)
            }

            let names = runningApps.map { $0.components(separatedBy: ".").last ?? $0 }.joined(separator: ", ")
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
