import AppKit
import OSLog

@MainActor
final class SidebarLayout: LayoutStrategy {

    private let resizeObserver = SidebarResizeObserver()

    /// When set, `applySidebarSwitch` uses these bundle IDs instead of `space.apps`
    /// to determine slot candidates, supporting runtime-moved apps.
    var liveAppsOverride: [String]?

    func apply(name: String, space: SpaceDefinition, config: TilrConfig, screen: NSScreen, operation: OperationType) {
        guard AXIsProcessTrusted() else {
            Logger.layout.info("layout 'sidebar': AX permission not granted — skipping positioning")
            return
        }
        guard let layout = space.layout else { return }

        switch operation {
        case .spaceSwitch:
            applySidebarSwitch(name: name, space: space, config: config, screen: screen, layout: layout)

        case .windowMove(let movedBundleID, let sourceSpace, let targetSpace):
            // Is the moved app moving INTO this sidebar space, or OUT of it?
            let isMovingInto = targetSpace == name
            if isMovingInto {
                applySidebarMoveInto(movedBundleID: movedBundleID, name: name, space: space, config: config, screen: screen, layout: layout)
            } else {
                applySidebarMoveOut(movedBundleID: movedBundleID, sourceSpace: sourceSpace, name: name, space: space, config: config, screen: screen, layout: layout)
            }
        }
    }

    // MARK: - Private layout helpers

    private func applySidebarSwitch(name: String, space: SpaceDefinition, config: TilrConfig, screen: NSScreen, layout: Layout) {
        let ratio = resizeObserver.ratio(for: name) ?? layout.ratio ?? 0.65
        let sf = screen.frame
        let mainBundleID = layout.main

        // Use live membership when available (includes runtime-moved apps);
        // fall back to config-pinned apps for spaces with no live membership.
        let candidateApps = liveAppsOverride ?? space.apps

        let runningApps = candidateApps.filter { bundleID in
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

        if mainIsVisible && !sidebarBundleIDs.isEmpty {
            resizeObserver.setExpectedFrames(mainFrame: mainFrame, sidebarFrame: sidebarFrame)
        }
        resizeObserver.startObserving(
            space: space,
            name: name,
            screen: screen,
            mainBundleID: mainBundleID,
            sidebarBundleIDs: sidebarBundleIDs,
            resizeWhileDragging: config.layouts.resizeWhileDragging
        )
    }

    /// App is being moved INTO this sidebar space.
    /// Hide all other sidebar-slot windows first, then position the moved app.
    private func applySidebarMoveInto(movedBundleID: String, name: String, space: SpaceDefinition, config: TilrConfig, screen: NSScreen, layout: Layout) {
        let ratio = resizeObserver.ratio(for: name) ?? layout.ratio ?? 0.65
        let sf = screen.frame
        let mainBundleID = layout.main

        // Resize then hide sidebar-slot apps (not main). Resize first so they
        // come up at the correct size if revealed later via cmd-tab.
        let sidebarFrame = CGRect(x: sf.minX + sf.width * ratio, y: sf.minY, width: sf.width * (1 - ratio), height: sf.height)
        let others = space.apps.filter { $0 != movedBundleID && $0 != mainBundleID }
        for bundleID in others {
            resizeObserver.setFrameAndSuppress(bundleID: bundleID, frame: sidebarFrame)
            setAppHidden(bundleID: bundleID, hidden: true)
            Logger.layout.info("sidebar move-into: resizing and hiding slot app '\(bundleID, privacy: .public)'")
        }

        // Apply the correct frame for the moved app's slot.
        let targetFrame: CGRect
        if movedBundleID == mainBundleID {
            targetFrame = CGRect(x: sf.minX, y: sf.minY, width: sf.width * ratio, height: sf.height)
        } else {
            // Moved into sidebar slot — give it the full sidebar column.
            targetFrame = CGRect(x: sf.minX + sf.width * ratio, y: sf.minY, width: sf.width * (1 - ratio), height: sf.height)
        }

        resizeObserver.setFrameAndSuppress(bundleID: movedBundleID, frame: targetFrame)
        let movedName = movedBundleID.components(separatedBy: ".").last ?? movedBundleID
        Logger.layout.info("applied sidebar layout (move-into): \(movedName, privacy: .public) frame x=\(targetFrame.origin.x, privacy: .public) w=\(targetFrame.width, privacy: .public)")

        // Re-start the observer so drag-resize settle blocks keep hidden apps in sync.
        let visibleSidebars = movedBundleID == mainBundleID ? [] : [movedBundleID]
        resizeObserver.startObserving(
            space: space,
            name: name,
            screen: screen,
            mainBundleID: mainBundleID,
            sidebarBundleIDs: visibleSidebars,
            hiddenSidebarBundleIDs: others,
            resizeWhileDragging: config.layouts.resizeWhileDragging
        )
    }

    /// App is being moved OUT OF this sidebar space (this layout is being applied to the now-vacated source space).
    /// Hide the moved app, find the next sidebar window to promote, and re-apply the sidebar layout.
    private func applySidebarMoveOut(movedBundleID: String, sourceSpace: String?, name: String, space: SpaceDefinition, config: TilrConfig, screen: NSScreen, layout: Layout) {
        // Hide the departing app.
        setAppHidden(bundleID: movedBundleID, hidden: true)
        Logger.layout.info("sidebar move-out: hiding departed app '\(movedBundleID, privacy: .public)'")

        // Find the next sidebar window to promote.
        if let nextID = nextWindowInSidebar(space: space, movedBundleID: movedBundleID) {
            setAppHidden(bundleID: nextID, hidden: false)
            Logger.layout.info("sidebar move-out: unhiding next sidebar window '\(nextID, privacy: .public)'")
        }

        // Re-apply the full sidebar layout for remaining windows.
        applySidebarSwitch(name: name, space: space, config: config, screen: screen, layout: layout)
    }

    // MARK: - Sidebar handoff helper

    /// Returns the next running app in `space` that should be promoted when `movedBundleID` departs.
    /// Skips the main app; returns the first running non-main, non-moved app in space order.
    private func nextWindowInSidebar(space: SpaceDefinition, movedBundleID: String) -> String? {
        let remaining = space.apps.filter { $0 != movedBundleID }
        let mainID = space.layout?.main

        for bundleID in remaining {
            if bundleID == mainID { continue }
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                return bundleID
            }
        }
        return nil
    }

    /// Forwards directly to the resize observer so callers outside this class
    /// can apply a frame without triggering a spurious drag-resize echo.
    func setFrameAndSuppress(bundleID: String, frame: CGRect) {
        resizeObserver.setFrameAndSuppress(bundleID: bundleID, frame: frame)
    }

    func frame(for bundleID: String, in space: SpaceDefinition, spaceName: String, screen: NSScreen) -> CGRect {
        let ratio = resizeObserver.ratio(for: spaceName) ?? space.layout?.ratio ?? 0.65
        let sf = screen.frame
        let mainFrame    = CGRect(x: sf.minX,                    y: sf.minY, width: sf.width * ratio,       height: sf.height)
        let sidebarFrame = CGRect(x: sf.minX + sf.width * ratio, y: sf.minY, width: sf.width * (1 - ratio), height: sf.height)
        return bundleID == space.layout?.main ? mainFrame : sidebarFrame
    }

    /// Re-registers the resize observer after an activation-driven sidebar swap.
    /// Call this after CMD+TAB brings a different sidebar app into focus.
    func reattachObserver(space: SpaceDefinition, name: String, screen: NSScreen, visibleSidebarBundleID: String, config: TilrConfig) {
        resizeObserver.startObserving(
            space: space,
            name: name,
            screen: screen,
            mainBundleID: space.layout?.main,
            sidebarBundleIDs: [visibleSidebarBundleID],
            resizeWhileDragging: config.layouts.resizeWhileDragging
        )
    }

    func stopObserving() {
        resizeObserver.stopObserving()
    }
}
