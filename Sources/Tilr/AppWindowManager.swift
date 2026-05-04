import AppKit
import Combine
import OSLog

// MARK: - ReflowReason

/// Describes why a sidebar-space reflow was triggered.
enum ReflowReason: String {
    case appLaunched    = "app-launched"
    case appTerminated  = "app-terminated"
    case appHidden      = "app-hidden"
    case appUnhidden    = "app-unhidden"
    case slotActivated  = "slot-activated"
}

// MARK: - AppWindowManager

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
    private let displayResolver: DisplayResolver
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
    private var activationGeneration: UInt64 = 0

    // Reflow debounce support
    private var pendingReflowWorkItem: DispatchWorkItem?
    private let reflowDebounceInterval: TimeInterval = 0.15

    // Suppression table: bundle IDs that should have their hide/unhide notifications
    // ignored because Tilr itself issued the hide (e.g. during a reflow).
    private var hideEventSuppression: [String: Date] = [:]

    // Suppression table: bundle IDs that should have their unhide notifications
    // ignored because Tilr itself issued the unhide (e.g. during slot activation).
    private var unhideEventSuppression: [String: Date] = [:]

    // Runtime live membership: spaceName → set of bundle IDs currently inhabiting the space.
    // Seeded from config at init; mutated on move, launch, and terminate.
    // Reads are used instead of config.space.apps wherever runtime state matters.
    private var liveSpaceMembership: [String: Set<String>] = [:]

    // Lifecycle observer tokens (stored separately so each can be cleaned up).
    private var launchObserverToken: NSObjectProtocol?
    private var terminateObserverToken: NSObjectProtocol?
    private var hideObserverToken: NSObjectProtocol?
    private var unhideObserverToken: NSObjectProtocol?

    init(configStore: ConfigStore, service: SpaceService, displayResolver: DisplayResolver) {
        self.configStore = configStore
        self.service = service
        self.displayResolver = displayResolver

        // Seed live membership from config: every configured space gets a set entry,
        // and every pinned app is added to its space's set.
        let seedConfig = configStore.current
        for (spaceName, space) in seedConfig.spaces {
            liveSpaceMembership[spaceName] = Set(space.apps)
        }

        service.onSpaceActivated
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

        // Step 3: launch observer
        self.launchObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier
                else { return }
                guard bundleID != Bundle.main.bundleIdentifier else { return }
                Logger.windows.info("handle: app launched '\(bundleID, privacy: .public)'")
                // Add to pinned space's live membership on launch.
                if let pinnedSpace = self.configStore.current.spaces.first(where: { $0.value.apps.contains(bundleID) })?.key {
                    self.liveSpaceMembership[pinnedSpace, default: []].insert(bundleID)
                }
                guard self.isMemberOfActiveSidebarSpace(bundleID: bundleID) else { return }
                // Give the new process time to register a window before reflowing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.reflowSidebarSpace(reason: .appLaunched, triggerBundleID: bundleID)
                }
            }
        }

        // Step 4: terminate observer
        self.terminateObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier
                else { return }
                guard bundleID != Bundle.main.bundleIdentifier else { return }
                Logger.windows.info("handle: app terminated '\(bundleID, privacy: .public)'")
                let wasMember = self.isMemberOfActiveSidebarSpace(bundleID: bundleID)
                // Remove from all spaces in live membership on terminate.
                for spaceName in self.liveSpaceMembership.keys {
                    self.liveSpaceMembership[spaceName]?.remove(bundleID)
                }
                guard wasMember else { return }
                self.reflowSidebarSpace(reason: .appTerminated, triggerBundleID: bundleID)
            }
        }

        // Step 5: hide observer
        self.hideObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier
                else { return }
                Logger.windows.info("handle: app hidden '\(bundleID, privacy: .public)'")
                // Drop events that Tilr itself triggered to prevent feedback loops.
                if let suppressUntil = self.hideEventSuppression[bundleID], suppressUntil > Date() {
                    Logger.windows.info("handle: suppressing hide event for '\(bundleID, privacy: .public)' (Tilr-issued)")
                    return
                }
                guard self.isMemberOfActiveSidebarSpace(bundleID: bundleID) else { return }
                self.reflowSidebarSpace(reason: .appHidden, triggerBundleID: bundleID)
            }
        }

        // Step 5: unhide observer
        self.unhideObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier
                else { return }
                Logger.windows.info("handle: app unhidden '\(bundleID, privacy: .public)'")
                if let suppressUntil = self.unhideEventSuppression[bundleID], suppressUntil > Date() {
                    Logger.windows.info("handle: suppressing unhide event for '\(bundleID, privacy: .public)' (Tilr-issued)")
                    return
                }
                guard self.isMemberOfActiveSidebarSpace(bundleID: bundleID) else { return }
                self.reflowSidebarSpace(reason: .appUnhidden, triggerBundleID: bundleID)
            }
        }
    }

    deinit {
        for token in [activationObserverToken, launchObserverToken, terminateObserverToken,
                      hideObserverToken, unhideObserverToken].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func fillScreenLastAppSnapshot() -> [String: String] {
        fillScreenLastApp
    }

    /// Returns the runtime live bundle IDs for the given space.
    /// SidebarLayout uses this instead of space.apps so moved-in apps are included.
    func liveAppsInSpace(name: String) -> [String] {
        Array(liveSpaceMembership[name] ?? [])
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

        // Update live membership: remove from source space, add to target space.
        if let src = sourceName {
            liveSpaceMembership[src]?.remove(bundleID)
        }
        liveSpaceMembership[targetName, default: []].insert(bundleID)

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

            // Capture generation after switchToSpace; handleSpaceActivated has incremented
            // it synchronously. Used by the retry callback to detect supersession.
            let gen = activationGeneration

            let screen = displayResolver.screen(forSpace: targetName)
            let targetSize: CGSize = {
                if let space = config.spaces[targetName], space.layout?.type == .sidebar {
                    return sidebarLayout.frame(for: bundleID, in: space, spaceName: targetName, screen: screen).size
                }
                return screen.frame.size
            }()

            retryUntilWindowMatches(bundleID: bundleID, targetSize: targetSize) { [weak self] in
                guard let self, self.activationGeneration == gen else { return }
                let currentConfig = self.configStore.current
                self.applyLayout(name: targetName, config: currentConfig, operation: operation)
            }
        }

        // Capture generation after switchToSpace; handleSpaceActivated has incremented
        // it synchronously. Used by the focus block below to detect supersession.
        let gen = activationGeneration

        // Focus the moved app after layout.apply returns (small delay to let AX settle).
        // Also set previousSidebarSlotApp here — AFTER handleSpaceActivated has run and
        // reset it to nil, so CMD+TAB knows which slot app is currently visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.activationGeneration == gen else { return }
            let currentConfig = self.configStore.current
            if let space = currentConfig.spaces[targetName], space.layout?.type == .sidebar,
               bundleID != space.layout?.main {
                self.previousSidebarSlotApp = bundleID
                Logger.windows.info("moveCurrentApp: set previousSidebarSlotApp='\(bundleID, privacy: .public)' for CMD+TAB handoff")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.service.sendNotification("moving \(appName) → \(targetName)")
        }
    }

    // MARK: - Private

    /// Helper to find which space contains a given bundle ID.
    private func spaceContaining(bundleID: String) -> String? {
        configStore.current.spaces
            .first(where: { $0.value.apps.contains(bundleID) })?
            .key
    }

    private func handleAppActivation(notification: Notification) {
        // Ignore our own programmatic activations.
        guard !isTilrActivating else { return }

        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier
        else { return }

        // Guard against activating Tilr itself.
        guard bundleID != Bundle.main.bundleIdentifier else { return }

        // Cross-space branch: if the activated app belongs to a different space, switch to it.
        if let targetSpace = spaceContaining(bundleID: bundleID),
           targetSpace != service.activeSpace {
            Logger.windows.info("follow-focus: '\(bundleID, privacy: .public)' lives in '\(targetSpace, privacy: .public)' — switching from '\(self.service.activeSpace ?? "none", privacy: .public)'")

            isTilrActivating = true
            activationResetWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.isTilrActivating = false }
            activationResetWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)

            // For fill-screen spaces, register the activated app as the fill-screen app
            // BEFORE switching so handleSpaceActivated picks it up immediately.
            let targetConfig = configStore.current
            if targetConfig.spaces[targetSpace]?.layout?.type == .fillScreen {
                fillScreenLastApp[targetSpace] = bundleID
                Logger.windows.info("pre-registered fill-screen app for '\(targetSpace, privacy: .public)': \(bundleID, privacy: .public)")
            }

            service.switchToSpace(targetSpace, reason: .hotkey)
            return
        }

        // From here on, work only with currentSpaceName.
        guard let spaceName = currentSpaceName,
              let space = configStore.current.spaces[spaceName]
        else { return }

        // Fill-screen branch: remember the last-focused app for the space.
        if space.layout?.type == .fillScreen, space.apps.contains(bundleID) {
            if fillScreenLastApp[spaceName] != bundleID {
                // Hide all other visible apps in this space before showing the new one.
                let previousApp = fillScreenLastApp[spaceName]
                if let prev = previousApp, prev != bundleID {
                    Logger.windows.info("hiding previous fill-screen app '\(prev, privacy: .public)' in space '\(spaceName, privacy: .public)'")
                    hideApp(bundleID: prev)
                }

                fillScreenLastApp[spaceName] = bundleID
                Logger.windows.info("remembered foreground app for fill-screen '\(spaceName, privacy: .public)': \(bundleID, privacy: .public)")
            }
            return
        }

        // Sidebar branch: handle CMD+TAB and other activations into sidebar-space apps.
        // Use live membership so apps moved in at runtime (not just config-pinned) are included.
        guard space.layout?.type == .sidebar,
              liveSpaceMembership[spaceName]?.contains(bundleID) ?? false
        else { return }

        let mainBundleID = space.layout?.main
        let isMainApp = (bundleID == mainBundleID)

        if isMainApp {
            // Main app always holds its position — no frame action needed.
            previousSidebarSlotApp = nil
            Logger.windows.info("app-activation: '\(bundleID, privacy: .public)' is sidebar main — no frame action")
            return
        }

        // It's a sidebar-slot app — delegate to the shared reflow helper.
        Logger.windows.info("handle: slot activated '\(bundleID, privacy: .public)'")
        // Suppress the unhide event that will fire when macOS unhides this app,
        // so only the slotActivated reflow runs (not appUnhidden).
        suppressUnhideEvent(for: bundleID)
        reflowSidebarSpace(reason: .slotActivated, triggerBundleID: bundleID)
    }

    private func handleSpaceActivated(name: String) {
        activationGeneration &+= 1
        let gen = activationGeneration

        // Suppress follow-focus during the entire space activation flow. macOS will
        // auto-promote a new frontmost app when we hide the current one, which would
        // otherwise trigger our cross-space follow-focus and recurse back. The reset
        // covers the 100ms layout delay + ~500ms settle window.
        isTilrActivating = true
        activationResetWorkItem?.cancel()
        let resetWork = DispatchWorkItem { [weak self] in self?.isTilrActivating = false }
        activationResetWorkItem = resetWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWork)

        currentSpaceName = name
        previousSidebarSlotApp = nil

        let config = configStore.current
        let space = config.spaces[name]

        // Tear down sidebar observer if new space is not sidebar layout
        if space?.layout?.type != .sidebar {
            sidebarLayout.stopObserving()
        }

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
            showApp(bundleID: bundleID)
        }

        // Hide apps not visible in this space.
        // Suppress hide notifications for all apps we're about to hide so that
        // incoming didHideApplicationNotification events don't trigger spurious
        // sidebar reflows during the space-switch settle period.
        for bundleID in hidingApps {
            suppressHideEvent(for: bundleID)
            hideApp(bundleID: bundleID)
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

        // Give the hide/unhide AppleEvents a brief window to be processed by their
        // target apps before issuing AX window-position calls — AX round-trips
        // otherwise crowd out pending AppleEvents and cause intermittent stuck apps.
        // Tightened to 100ms (from the Hammerspoon reference's 200ms) for snappier
        // space-switch response. If AX failures appear in logs (e.g. "no content
        // window for X"), bump this back up — the AppleEvents need more time to
        // settle before AX will see the freshly-unhidden windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.activationGeneration == gen else {
                Logger.windows.info("space activation \(gen, privacy: .public) stale (now \(self?.activationGeneration ?? 0, privacy: .public)) — dropping queued layout for '\(name, privacy: .public)'")
                return
            }

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
                let screen = displayResolver.screen(forSpace: name)
                let targetSize = screen.frame.size
                retryUntilWindowMatches(bundleID: targetBundleID, targetSize: targetSize) { [weak self] in
                    guard let self, self.activationGeneration == gen else { return }
                    self.applyLayout(name: name, config: config)
                }
            }
        }
    }

    private func applyLayout(name: String, config: TilrConfig, operation: OperationType = .spaceSwitch(spaceName: "")) {
        guard let space = config.spaces[name], let layout = space.layout else { return }

        let screen = displayResolver.screen(forSpace: name)

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
            // Feed runtime live membership into SidebarLayout so slot candidates
            // include apps moved in at runtime, not just config-pinned apps.
            sidebarLayout.liveAppsOverride = liveAppsInSpace(name: name)
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

    // MARK: - Sidebar reflow

    /// Returns true if the given bundle ID belongs to the currently active sidebar space.
    /// Uses runtime live membership rather than config, so apps moved in at runtime are included.
    private func isMemberOfActiveSidebarSpace(bundleID: String) -> Bool {
        guard let spaceName = currentSpaceName,
              let space = configStore.current.spaces[spaceName],
              space.layout?.type == .sidebar
        else { return false }
        return liveSpaceMembership[spaceName]?.contains(bundleID) ?? false
    }

    /// Debounced reflow of the current sidebar space.
    ///
    /// All lifecycle events (launch, terminate, hide, unhide, slot-activated) funnel
    /// through here so logic stays in one place and rapid successive events are coalesced.
    private func reflowSidebarSpace(reason: ReflowReason, triggerBundleID: String) {
        guard let spaceName = currentSpaceName,
              let space = configStore.current.spaces[spaceName],
              space.layout?.type == .sidebar
        else { return }

        Logger.windows.info("reflow: \(reason.rawValue, privacy: .public) for '\(triggerBundleID, privacy: .public)' in '\(spaceName, privacy: .public)'")
        TilrLogger.shared.log("reflow: \(reason.rawValue) for '\(triggerBundleID)' in '\(spaceName)'", category: "windows")

        // Debounce: cancel any already-pending reflow and schedule a new one.
        pendingReflowWorkItem?.cancel()

        let gen = activationGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activationGeneration == gen else { return }

            let config = self.configStore.current
            guard let currentSpace = config.spaces[spaceName],
                  currentSpace.layout?.type == .sidebar
            else { return }

            // For slot-activated: frame new slot app, hide previous, reattach observer.
            // This is the targeted logic from the original handleAppActivation sidebar branch.
            if reason == .slotActivated {
                let mainBundleID = currentSpace.layout?.main
                let prev = self.previousSidebarSlotApp

                Logger.windows.info("reflow: slot '\(triggerBundleID, privacy: .public)' activated — hiding prev '\(prev ?? "none", privacy: .public)'")

                // Frame the new slot app into its sidebar frame.
                let screen = self.displayResolver.screen(forSpace: spaceName)
                let targetFrame = self.sidebarLayout.frame(
                    for: triggerBundleID, in: currentSpace, spaceName: spaceName, screen: screen)

                // Always run the retry loop on slot-activated. The wasHidden check is
                // unreliable here because macOS unhides the app synchronously on
                // activation, so by the time this debounced block runs the app is
                // already visible. Browsers (Zen) routinely ignore the first AX
                // setFrame after unhide and assert their AppKit-restored frame back —
                // so we must retry until the actual window size matches the target.
                self.sidebarLayout.setFrameAndSuppress(bundleID: triggerBundleID, frame: targetFrame)
                self.sidebarLayout.reattachObserver(
                    space: currentSpace, name: spaceName, screen: screen,
                    visibleSidebarBundleID: triggerBundleID, config: config)
                retryUntilWindowMatches(bundleID: triggerBundleID, targetSize: targetFrame.size) {
                    [weak self] in
                    guard let self, self.activationGeneration == gen else { return }
                    self.sidebarLayout.setFrameAndSuppress(bundleID: triggerBundleID, frame: targetFrame)
                }

                // Hide the previous slot app.
                if let prev, prev != triggerBundleID, prev != mainBundleID {
                    self.suppressHideEvent(for: prev)
                    hideApp(bundleID: prev)
                }

                // Update which slot app is currently visible.
                self.previousSidebarSlotApp = triggerBundleID
                return
            }

            // For launch / terminate / hide / unhide: full layout reapply.
            self.applyLayout(name: spaceName, config: config)

            // Retry until the main app's window width matches the target.
            if let mainBundleID = currentSpace.layout?.main {
                let screen = self.displayResolver.screen(forSpace: spaceName)
                let targetFrame = self.sidebarLayout.frame(
                    for: mainBundleID, in: currentSpace, spaceName: spaceName, screen: screen)
                retryUntilWindowMatches(bundleID: mainBundleID, targetSize: targetFrame.size) {
                    [weak self] in
                    guard let self, self.activationGeneration == gen else { return }
                    self.applyLayout(name: spaceName, config: config)
                }
            }

            // Also retry the trigger app's frame — needed for launch where the app
            // may not honour the first AX setFrame (e.g. Marq comes up at default
            // height and width matches but height doesn't).
            if triggerBundleID != currentSpace.layout?.main {
                let screen = self.displayResolver.screen(forSpace: spaceName)
                let triggerFrame = self.sidebarLayout.frame(
                    for: triggerBundleID, in: currentSpace, spaceName: spaceName, screen: screen)
                retryUntilWindowMatches(bundleID: triggerBundleID, targetSize: triggerFrame.size) {
                    [weak self] in
                    guard let self, self.activationGeneration == gen else { return }
                    self.sidebarLayout.setFrameAndSuppress(bundleID: triggerBundleID, frame: triggerFrame)
                }
            }
        }

        pendingReflowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reflowDebounceInterval, execute: work)
    }

    /// Record that Tilr is about to issue a hide for `bundleID` so the hide notification
    /// observer can ignore it and avoid a reflow feedback loop.
    private func suppressHideEvent(for bundleID: String) {
        // Prune expired entries while we're here.
        let now = Date()
        hideEventSuppression = hideEventSuppression.filter { $0.value > now }
        hideEventSuppression[bundleID] = now.addingTimeInterval(0.5)
    }

    /// Record that Tilr is about to issue an unhide for `bundleID` so the unhide notification
    /// observer can ignore it and avoid a reflow feedback loop.
    private func suppressUnhideEvent(for bundleID: String) {
        // Prune expired entries while we're here.
        let now = Date()
        unhideEventSuppression = unhideEventSuppression.filter { $0.value > now }
        unhideEventSuppression[bundleID] = now.addingTimeInterval(0.5)
    }
}
