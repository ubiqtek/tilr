import AppKit
import OSLog

struct FillScreenLayout: LayoutStrategy {

    func apply(name: String, space: SpaceDefinition, config: TilrConfig, screen: NSScreen) {
        guard AXIsProcessTrusted() else {
            Logger.layout.info("layout 'fill-screen': AX permission not granted — skipping positioning")
            return
        }
        let sf = screen.frame

        let runningApps = space.apps.filter { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }

        guard !runningApps.isEmpty else { return }

        for bundleID in runningApps {
            setWindowFrame(bundleID: bundleID, frame: sf)
        }

        let names = runningApps.map { $0.components(separatedBy: ".").last ?? $0 }.joined(separator: ", ")
        Logger.layout.info("applied fill-screen layout: [\(names, privacy: .public)]")
    }
}
