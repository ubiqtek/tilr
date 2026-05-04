import AppKit
import Foundation

/// Initializes TilrState with displays only (empty spaces and no apps).
public class StateInitializer {
    private let configStore: ConfigStore
    private let displayStateStore = DisplayStateStore.self

    public init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    /// Build initial TilrState from displays only (no spaces, no apps).
    /// Returns both the state and the initialize command that produced it.
    public func initializeState() -> (state: TilrState, command: Command) {
        // Load display UUID↔ID mappings.
        var displayState = displayStateStore.load()

        // Build displays from connected screens with empty spaces.
        let displays = NSScreen.screens.compactMap { screen -> Display? in
            guard let uuid = displayUUID(for: screen) else { return nil }

            let displayId = displayStateStore.resolveId(for: uuid, state: &displayState)
            let displayName = screen.localizedName

            let display = Display(
                id: displayId,
                uuid: uuid,
                name: displayName,
                spaces: [], // Empty spaces array - will be populated by pipeline
                activeSpaceId: nil // Will be set by pipeline
            )

            return display
        }

        // Save updated display mappings.
        try? displayStateStore.save(displayState)

        let state = TilrState(displays: displays)

        TilrLogger.shared.log(
            "[state] Initialized TilrState with \(displays.count) displays",
            category: "state"
        )

        return (state: state, command: .initialise)
    }
}
