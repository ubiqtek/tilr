import AppKit
import Combine
import OSLog

/// Output adaptor — subscribes to SpaceService.onSpaceActivated and
/// hides/shows running apps based on space membership.
///
/// - Apps in the activated space are unhidden.
/// - All other apps are hidden. The hide candidate set is the union of all
///   configured-space apps and running regular-UI apps, guaranteeing configured
///   apps are always candidates even if NSWorkspace momentarily omits them.
/// - Tilr itself is never hidden.
@MainActor
final class AppWindowManager {

    private let configStore: ConfigStore
    private let service: SpaceService
    private var cancellables = Set<AnyCancellable>()
    private let sidebarLayout = SidebarLayout()
    private let fillScreenLayout = FillScreenLayout()

    private var currentSpaceName: String?
    private var fillScreenLastApp: [String: String] = [:]  // spaceName → bundleID
    private var previousSidebarSlotApp: String?
    private var pendingMoveInto: (targetSpace: String, movedBundleID: String)?
    private var isTilrActivating = false
    private var activationResetWorkItem: DispatchWorkItem?
    private var activationObserverToken: NSObjectProtocol?

    init(configStore: ConfigStore, service: SpaceService) {
        self.configStore = configStore
        self.service = service

        service.onSpaceActivated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleSpaceActivated(name: event.name)
            }
            .store(in: &cancellables)

        self.activationObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleAppActivation(notification: notification)
            }
        }
    }

    deinit {
        if let token = activationObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func fillScreenLastAppSnapshot() -> [String: String] {
        fillScreenLastApp
    }

    func moveCurrentApp(toSpaceName targetName: String) {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        guard bundleID != Bundle.main.bundleIdentifier else { return }

        var config = configStore.current

        guard config.spaces[targetName] != nil else {
            Logger.windows.warning("moveCurrentApp: target space '\(targetName, privacy: .public)' not found")
            return
        }

        let sourceName = config.spaces.first(where: { $0.value.apps.contains(bundleID) })?.key

        if let src = sourceName {
            config.spaces[src]?.apps.removeAll { $0 == bundleID }
        }

        config.spaces[targetName]?.apps.insert(bundleID, at: 0)

        configStore.updateInMemory(config)

        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? bundleID
        Logger.windows.info("moved '\(appName, privacy: .public)' from '\(sourceName ?? "none", privacy: .public)' to '\(targetName, privacy: .public)'")
        TilrLogger.shared.log("moved '\(appName)' from '\(sourceName ?? "none")' to '\(targetName)'", category: "windows")

        let operation = OperationType.windowMove(
            movedBundleID: bundleID,
            sourceSpace: sourceName,
            targetSpace: targetName
        )

        let isFillScreen = config.spaces[targetName]?.layout?.type == .fillScreen

        if isFillScreen {
            // For fill-screen targets, register the moved app as the fill-screen app
            // BEFORE switching spaces so handleSpaceActivated picks it up immediately.
            // The standard handleSpaceActivated path handles show/hide/layout with its
            // own 200ms settle delay — no second layout apply needed.
            fillScreenLastApp[targetName] = bundleID
            service.switchToSpace(targetName, reason: .hotkey)
        } else {
            pendingMoveInto = (targetSpace: targetName, movedBundleID: bundleID)
            service.switchToSpace(targetName, reason: .hotkey)

            let screen = NSScreen.main ?? NSScreen.screens[0]
            let targetSize: CGSize = {
                if let space = config.spaces[targetName], space.layout?.type == .sidebar {
                    return sidebarLayout.frame(for: bundleID, in: space, spaceName: targetName, screen: screen).size
                }
                return screen.frame.size
            }()

            retryUntilWindowMatches(bundleID: bundleID, targetSize: targetSize) { [weak self] in
                guard let self else { return }
                let currentConfig = self.configStore.current
                self.applyLayout(name: targetName, config: currentConfig, operation: operation)
            }
        }

        // Focus the moved app after layout.apply returns (small delay to let AX settle).
        // Also set previousSidebarSlotApp here — AFTER handleSpaceActivated has run and
        // reset it to nil, so CMD+TAB knows which slot app is currently visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let currentConfig = self.configStore.current
            if let space = currentConfig.spaces[targetName], space.layout?.type == .sidebar,
               bundleID != space.layout?.main {
                self.previousSidebarSlotApp = bundleID
                Logger.windows.info("moveCurrentApp: set previousSidebarSlotApp='\(bundleID, privacy: .public)' for CMD+TAB handoff")
            }
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                self.isTilrActivating = true
                self.activationResetWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.isTilrActivating = false }
                self.activationResetWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                app.activate(options: [])
                Logger.windows.info("moveCurrentApp: focused '\(bundleID, privacy: .public)' after move")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.service.sendNotification("moving \(appName) → \(targetName)")
        }
    }

    // MARK: - Private

    private func handleAppActivation(notification: Notification) {
        // Ignore our own programmatic activations.
        guard !isTilrActivating else { return }

        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              let spaceName = currentSpaceName,
              let space = configStore.current.spaces[spaceName]
        else { return }

        // Fill-screen branch: remember the last-focused app for the space.
        if space.layout?.type == .fillScreen, space.apps.contains(bundleID) {
            if fillScreenLastApp[spaceName] != bundleID {
                fillScreenLastApp[spaceName] = bundleID
                Logger.windows.info("remembered foreground app for fill-screen '\(spaceName, privacy: .public)': \(bundleID, privacy: .public)")
            }
            return
        }

        // Sidebar branch: handle CMD+TAB and other activations into sidebar-space apps.
        guard space.layout?.type == .sidebar,
              space.apps.contains(bundleID)
        else { return }

        let mainBundleID = space.layout?.main
        let isMainApp = (bundleID == mainBundleID)

        if isMainApp {
            // Main app always holds its position — no frame action needed.
            previousSidebarSlotApp = nil
            Logger.windows.info("app-activation: '\(bundleID, privacy: .public)' is sidebar main — no frame action")
            return
        }

        // It's a sidebar-slot app — resize it into its frame and hide the previous slot app.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let targetFrame = sidebarLayout.frame(for: bundleID, in: space, spaceName: spaceName, screen: screen)

        let prev = previousSidebarSlotApp
        Logger.windows.info("app-activation: '\(bundleID, privacy: .public)' is sidebar slot — applying frame, hiding prev '\(prev ?? "none", privacy: .public)'")

        if let prev, prev != bundleID, prev != mainBundleID {
            setAppHidden(bundleID: prev, hidden: true)
        }
        previousSidebarSlotApp = bundleID

        // Delay the frame call if the app was hidden — AX is not ready immediately after unhide.
        let wasHidden = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.isHidden ?? false
        let config = configStore.current
        if wasHidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.sidebarLayout.setFrameAndSuppress(bundleID: bundleID, frame: targetFrame)
                self.sidebarLayout.reattachObserver(space: space, name: spaceName, screen: screen, visibleSidebarBundleID: bundleID, config: config)
                retryUntilWindowMatches(bundleID: bundleID, targetSize: targetFrame.size) { [weak self] in
                    self?.sidebarLayout.setFrameAndSuppress(bundleID: bundleID, frame: targetFrame)
                }
            }
        } else {
            sidebarLayout.setFrameAndSuppress(bundleID: bundleID, frame: targetFrame)
            sidebarLayout.reattachObserver(space: space, name: spaceName, screen: screen, visibleSidebarBundleID: bundleID, config: config)
        }
    }

    private func handleSpaceActivated(name: String) {
        currentSpaceName = name
        previousSidebarSlotApp = nil

        let config = configStore.current
        let space = config.spaces[name]

        // Resolve the target app for fill-screen layouts:
        // prefer the user's last-focused app (if still in the space's apps),
        // else layout.main (if in the space's apps),
        // else the first app in the space.
        let fillScreenTarget: String? = {
            guard let space, space.layout?.type == .fillScreen else { return nil }
            if let recorded = fillScreenLastApp[name], space.apps.contains(recorded) {
                return recorded
            }
            if let main = space.layout?.main, space.apps.contains(main) {
                return main
            }
            return space.apps.first
        }()

        // Consume the pending move-into hint (set by moveCurrentApp before switchToSpace).
        let moveInto = pendingMoveInto.flatMap { $0.targetSpace == name ? $0 : nil }
        pendingMoveInto = nil

        // Compute the set of apps that should be VISIBLE in this space.
        // Fill-screen: just the target. Sidebar move-into: only main + moved app
        // (so handleSpaceActivated never unhides sidebar apps that should stay hidden).
        // Sidebar switch: all apps.
        let visibleApps: Set<String> = {
            guard let space else { return [] }
            if space.layout?.type == .fillScreen {
                return fillScreenTarget.map { Set([$0]) } ?? []
            }
            if space.layout?.type == .sidebar, let move = moveInto {
                var visible = Set([move.movedBundleID])
                if let main = space.layout?.main { visible.insert(main) }
                return visible
            }
            return Set(space.apps)
        }()

        // Hide-candidate set: union of all configured apps (guarantees config apps are
        // always candidates even if NSWorkspace transiently omits them) and all running
        // regular-UI apps (catches unassigned apps). Subtract visibleApps and Tilr itself.
        let allConfiguredApps = Set(config.spaces.values.flatMap { $0.apps })
        let ourBundleID = Bundle.main.bundleIdentifier
        let runningRegularApps: Set<String> = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleIdentifier }
        )
        let hidingApps = allConfiguredApps
            .union(runningRegularApps)
            .subtracting(visibleApps)
            .subtracting([ourBundleID].compactMap { $0 })

        // Derive human-readable names for the log line.
        let showingNames = appDisplayNames(for: visibleApps)
        let hidingNames  = appDisplayNames(for: hidingApps)

        Logger.windows.info(
            "applying space '\(name, privacy: .public)': showing \(showingNames, privacy: .public), hiding \(hidingNames, privacy: .public)"
        )
        TilrLogger.shared.log("applying space '\(name)': showing \(showingNames), hiding \(hidingNames)", category: "windows")

        // Show the visible apps first — so macOS has a foreground target before
        // we hide the old space's foreground app. Matches Hammerspoon's ordering.
        for bundleID in visibleApps {
            setAppHidden(bundleID: bundleID, hidden: false)
        }

        // Hide apps not visible in this space.
        for bundleID in hidingApps {
            setAppHidden(bundleID: bundleID, hidden: true)
        }

        // Decide which app to bring to the front. For fill-screen that's the single
        // visible app (which is already the fillScreenTarget). For sidebar or no
        // layout we prefer the configured layout.main.
        let activateBundleID: String? = {
            if space?.layout?.type == .fillScreen {
                return fillScreenTarget
            }
            return space?.layout?.main
        }()

        // Give the hide/unhide AppleEvents ~200 ms to be processed by their target
        // apps before issuing AX window-position calls — AX round-trips otherwise
        // crowd out pending AppleEvents and cause intermittent stuck apps. This
        // matches the Hammerspoon reference implementation's `hs.timer.doAfter(0.2)`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }

            if let bundleID = activateBundleID {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    self.isTilrActivating = true
                    self.activationResetWorkItem?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        self?.isTilrActivating = false
                    }
                    self.activationResetWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)

                    app.activate(options: [])
                } else {
                    Logger.windows.info("activate target '\(bundleID, privacy: .public)' is not running — skipping activate")
                }
            }

            self.applyLayout(name: name, config: config)

            if space?.layout?.type == .fillScreen, let targetBundleID = activateBundleID {
                let screen = NSScreen.main ?? NSScreen.screens[0]
                let targetSize = screen.frame.size
                retryUntilWindowMatches(bundleID: targetBundleID, targetSize: targetSize) { [weak self] in
                    guard let self else { return }
                    self.applyLayout(name: name, config: config)
                }
            }
        }
    }

    private func applyLayout(name: String, config: TilrConfig, operation: OperationType = .spaceSwitch(spaceName: "")) {
        guard let space = config.spaces[name], let layout = space.layout else { return }

        let screen = NSScreen.main ?? NSScreen.screens[0]

        // Resolve the operation's spaceName default when caller used the bare default.
        let resolvedOperation: OperationType
        if case .spaceSwitch(let sn) = operation, sn.isEmpty {
            resolvedOperation = .spaceSwitch(spaceName: name)
        } else {
            resolvedOperation = operation
        }

        let strategy: LayoutStrategy
        switch layout.type {
        case .sidebar:
            strategy = sidebarLayout
        case .fillScreen:
            sidebarLayout.stopObserving()
            strategy = fillScreenLayout
        }

        strategy.apply(name: name, space: space, config: config, screen: screen, operation: resolvedOperation)
    }

    /// Returns a bracket-enclosed list of localised app names (falling back
    /// to the bundle ID) for use in log messages.
    private func appDisplayNames(for bundleIDs: Set<String>) -> String {
        let names = bundleIDs.sorted().map { bundleID -> String in
            // Prefer the localised name from a running instance.
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let localName = app.localizedName {
                return localName
            }
            // Fall back to the last component of the bundle ID (e.g. "Ghostty").
            return bundleID.components(separatedBy: ".").last ?? bundleID
        }
        return "[" + names.joined(separator: ", ") + "]"
    }
}
