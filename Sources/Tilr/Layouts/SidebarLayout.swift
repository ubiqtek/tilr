import AppKit
import OSLog

struct SidebarLayout: LayoutStrategy {

    func apply(space: SpaceDefinition, config: TilrConfig, screen: NSScreen) {
        guard let layout = space.layout else { return }

        let ratio = layout.ratio ?? 0.65
        let sf = screen.frame
        let mainBundleID = layout.main

        let runningApps = space.apps.filter { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }

        guard !runningApps.isEmpty else { return }

        let mainIsVisible = mainBundleID.map { id in runningApps.contains(id) } ?? false
        let sidebarBundleIDs = runningApps.filter { $0 != mainBundleID }

        let mainFrame    = CGRect(x: sf.minX,                y: sf.minY, width: sf.width * ratio,           height: sf.height)
        let sidebarFrame = CGRect(x: sf.minX + sf.width * ratio, y: sf.minY, width: sf.width * (1 - ratio), height: sf.height)

        if mainIsVisible && !sidebarBundleIDs.isEmpty, let mainID = mainBundleID {
            setWindowFrame(bundleID: mainID, frame: mainFrame)
            for bundleID in sidebarBundleIDs {
                setWindowFrame(bundleID: bundleID, frame: sidebarFrame)
            }
            let sidebarNames = sidebarBundleIDs.map { $0.components(separatedBy: ".").last ?? $0 }.joined(separator: ", ")
            let mainName = mainID.components(separatedBy: ".").last ?? mainID
            Logger.windows.info("applied sidebar layout: main=\(mainName, privacy: .public), ratio=\(ratio, privacy: .public), sidebars=[\(sidebarNames, privacy: .public)]")
        } else if mainIsVisible, let mainID = mainBundleID {
            setWindowFrame(bundleID: mainID, frame: sf)
            Logger.windows.info("applied sidebar layout: main alone → fill")
        } else if !sidebarBundleIDs.isEmpty {
            for bundleID in sidebarBundleIDs {
                setWindowFrame(bundleID: bundleID, frame: sf)
            }
            Logger.windows.info("applied sidebar layout: sidebars alone → fill")
        }
    }
}
