import AppKit
import OSLog

struct FillScreenLayout: LayoutStrategy {

    func apply(space: SpaceDefinition, config: TilrConfig, screen: NSScreen) {
        let sf = screen.frame

        let runningApps = space.apps.filter { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }

        guard !runningApps.isEmpty else { return }

        for bundleID in runningApps {
            setWindowFrame(bundleID: bundleID, frame: sf)
        }

        let names = runningApps.map { $0.components(separatedBy: ".").last ?? $0 }.joined(separator: ", ")
        Logger.windows.info("applied fill-screen layout: [\(names, privacy: .public)]")
    }
}
