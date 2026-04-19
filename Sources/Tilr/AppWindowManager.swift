import AppKit
import Combine
import OSLog

/// Output adaptor — subscribes to SpaceService.onSpaceActivated and
/// hides/shows running apps based on space membership.
///
/// - Apps in the activated space are unhidden (shown).
/// - Apps that are in ANY configured space but NOT in the activated space
///   are hidden.
/// - Apps whose bundle IDs do not appear in any configured space are
///   left untouched.
@MainActor
final class AppWindowManager {

    private let configStore: ConfigStore
    private var cancellables = Set<AnyCancellable>()
    private let sidebarLayout = SidebarLayout()
    private let fillScreenLayout = FillScreenLayout()

    init(configStore: ConfigStore, service: SpaceService) {
        self.configStore = configStore

        service.onSpaceActivated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleSpaceActivated(name: event.name)
            }
            .store(in: &cancellables)
    }

    // MARK: - Private

    private func handleSpaceActivated(name: String) {
        let config = configStore.current

        // Compute the union of ALL bundle IDs across every configured space.
        let allSpaceApps = Set(config.spaces.values.flatMap { $0.apps })

        // Compute this space's bundle IDs.
        let thisSpaceApps = Set(config.spaces[name]?.apps ?? [])

        // Derive human-readable names for the log line.
        let showingNames  = appDisplayNames(for: thisSpaceApps)
        let hidingApps    = allSpaceApps.subtracting(thisSpaceApps)
        let hidingNames   = appDisplayNames(for: hidingApps)

        Logger.windows.info(
            "applying space '\(name, privacy: .public)': showing \(showingNames, privacy: .public), hiding \(hidingNames, privacy: .public)"
        )

        // Hide apps in other spaces (skip if already hidden).
        for bundleID in hidingApps {
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if instances.count > 1 {
                Logger.windows.debug("multiple instances (\(instances.count, privacy: .public)) for bundle '\(bundleID, privacy: .public)'")
            }
            for app in instances {
                guard !app.isHidden else { continue }
                let result = app.hide()
                Logger.windows.debug("hide result for '\(bundleID, privacy: .public)': \(result, privacy: .public)")
            }
        }

        // Show apps in this space (skip if already visible).
        for bundleID in thisSpaceApps {
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if instances.count > 1 {
                Logger.windows.debug("multiple instances (\(instances.count, privacy: .public)) for bundle '\(bundleID, privacy: .public)'")
            }
            for app in instances {
                guard app.isHidden else { continue }
                let result = app.unhide()
                Logger.windows.debug("unhide result for '\(bundleID, privacy: .public)': \(result, privacy: .public)")
            }
        }

        // Optionally activate the layout.main app so it comes to the front.
        if let mainBundleID = config.spaces[name]?.layout?.main {
            if let mainApp = NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleID).first {
                mainApp.activate(options: [])
            } else {
                Logger.windows.info("layout.main app '\(mainBundleID, privacy: .public)' is not running — skipping activate")
            }
        }

        applyLayout(name: name, config: config)
    }

    private func applyLayout(name: String, config: TilrConfig) {
        guard let space = config.spaces[name], let layout = space.layout else { return }

        let screen = NSScreen.main ?? NSScreen.screens[0]

        let strategy: LayoutStrategy
        switch layout.type {
        case .sidebar:
            strategy = sidebarLayout
        case .fillScreen:
            sidebarLayout.stopObserving()
            strategy = fillScreenLayout
        }

        strategy.apply(name: name, space: space, config: config, screen: screen)
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
