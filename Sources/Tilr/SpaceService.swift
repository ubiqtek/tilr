import Combine
import Foundation
import OSLog

/// The domain service. All space changes go through here.
/// @MainActor — callers from background threads must hop to main before calling.
@MainActor
final class SpaceService {

    // MARK: - Read-only state

    private(set) var activeSpace: String? = nil

    // MARK: - Event channels

    /// Fired when a real space becomes active (state updated).
    let onSpaceActivated = PassthroughSubject<(name: String, reason: ActivationReason), Never>()

    /// Fired for user-visible messages that do NOT change the active space
    /// (e.g. "↺ Config" when no default space is configured).
    let onNotification = PassthroughSubject<String, Never>()

    // MARK: - Dependencies

    private let configStore: ConfigStore

    // MARK: - Init

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    // MARK: - Commands

    /// Switch to a named space. Logs, updates state, fires onSpaceActivated.
    func switchToSpace(_ name: String, reason: ActivationReason) {
        Logger.space.info("switching to '\(name, privacy: .public)' (\(reason.logDescription, privacy: .public))")
        activeSpace = name
        onSpaceActivated.send((name: name, reason: reason))
    }

    /// Send a user-visible notification message (no state change).
    func sendNotification(_ message: String) {
        onNotification.send(message)
    }

    /// Apply the current config — activate the display 1 default space if
    /// one is configured, otherwise fire a notification.
    func applyConfig(reason: ActivationReason) {
        let config = configStore.current
        guard let ref = config.displays["1"]?.defaultSpace else {
            Logger.space.info("applyConfig(\(reason.logDescription, privacy: .public)) — no default space for display 1")
            onNotification.send("↺ Config")
            return
        }

        let spaceName: String?
        if ref.count == 1 {
            spaceName = config.spaces.first(where: { $0.value.id == ref })?.key
        } else {
            spaceName = config.spaces[ref] != nil ? ref : nil
        }

        guard let name = spaceName else {
            Logger.space.warning("applyConfig: default space '\(ref, privacy: .public)' not found in config")
            onNotification.send("↺ Config")
            return
        }

        Logger.space.info("activating '\(name, privacy: .public)' (\(reason.logDescription, privacy: .public))")
        activeSpace = name
        onSpaceActivated.send((name: name, reason: reason))
    }
}
