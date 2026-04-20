import AppKit
import OSLog

@MainActor
final class SidebarLayout: LayoutStrategy {

    private let resizeObserver = SidebarResizeObserver()

    func apply(name: String, space: SpaceDefinition, config: TilrConfig, screen: NSScreen) {
        guard AXIsProcessTrusted() else {
            Logger.layout.info("layout 'sidebar': AX permission not granted — skipping positioning")
            return
        }
        guard let layout = space.layout else { return }

        let ratio = resizeObserver.ratio(for: name) ?? layout.ratio ?? 0.65
        let sf = screen.frame
        let mainBundleID = layout.main

        let runningApps = space.apps.filter { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }

        guard !runningApps.isEmpty else { return }

        let mainIsVisible = mainBundleID.map { id in runningApps.contains(id) } ?? false
        let sidebarBundleIDs = runningApps.filter { $0 != mainBundleID }

        let mainFrame    = CGRect(x: sf.minX,                    y: sf.minY, width: sf.width * ratio,           height: sf.height)
        let sidebarFrame = CGRect(x: sf.minX + sf.width * ratio, y: sf.minY, width: sf.width * (1 - ratio),     height: sf.height)

        if mainIsVisible && !sidebarBundleIDs.isEmpty, let mainID = mainBundleID {
            resizeObserver.setFrameAndSuppress(bundleID: mainID, frame: mainFrame)
            for bundleID in sidebarBundleIDs {
                resizeObserver.setFrameAndSuppress(bundleID: bundleID, frame: sidebarFrame)
            }
            let sidebarNames = sidebarBundleIDs.map { $0.components(separatedBy: ".").last ?? $0 }.joined(separator: ", ")
            let mainName = mainID.components(separatedBy: ".").last ?? mainID
            Logger.layout.info("applied sidebar layout: main=\(mainName, privacy: .public), ratio=\(ratio, privacy: .public), sidebars=[\(sidebarNames, privacy: .public)]")
        } else if mainIsVisible, let mainID = mainBundleID {
            resizeObserver.setFrameAndSuppress(bundleID: mainID, frame: sf)
            Logger.layout.info("applied sidebar layout: main alone → fill")
        } else if !sidebarBundleIDs.isEmpty {
            for bundleID in sidebarBundleIDs {
                resizeObserver.setFrameAndSuppress(bundleID: bundleID, frame: sf)
            }
            Logger.layout.info("applied sidebar layout: sidebars alone → fill")
        }

        if config.layouts.resizeObserverEnabled {
            if mainIsVisible && !sidebarBundleIDs.isEmpty {
                resizeObserver.setExpectedFrames(mainFrame: mainFrame, sidebarFrame: sidebarFrame)
            }
            resizeObserver.startObserving(
                space: space,
                name: name,
                screen: screen,
                mainBundleID: mainBundleID,
                sidebarBundleIDs: sidebarBundleIDs
            )
        } else {
            resizeObserver.stopObserving()
        }
    }

    func stopObserving() {
        resizeObserver.stopObserving()
    }
}
