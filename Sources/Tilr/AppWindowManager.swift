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

        // Compute this space's bundle IDs.
        let thisSpaceApps = Set(config.spaces[name]?.apps ?? [])

        // Hide-candidate set: union of all configured apps (guarantees config apps are
        // always candidates even if NSWorkspace transiently omits them) and all running
        // regular-UI apps (catches unassigned apps). Subtract this space and Tilr itself.
        let allConfiguredApps = Set(config.spaces.values.flatMap { $0.apps })
        let ourBundleID = Bundle.main.bundleIdentifier
        let runningRegularApps: Set<String> = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleIdentifier }
        )
        let hidingApps = allConfiguredApps
            .union(runningRegularApps)
            .subtracting(thisSpaceApps)
            .subtracting([ourBundleID].compactMap { $0 })

        // Derive human-readable names for the log line.
        let showingNames  = appDisplayNames(for: thisSpaceApps)
        let hidingNames   = appDisplayNames(for: hidingApps)

        Logger.windows.info(
            "applying space '\(name, privacy: .public)': showing \(showingNames, privacy: .public), hiding \(hidingNames, privacy: .public)"
        )

        // Hide apps in other spaces.
        for bundleID in hidingApps {
            setAppHidden(bundleID: bundleID, hidden: true)
        }

        // Show apps in this space.
        for bundleID in thisSpaceApps {
            setAppHidden(bundleID: bundleID, hidden: false)
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
