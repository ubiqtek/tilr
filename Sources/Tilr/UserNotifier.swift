import Combine
import Foundation

/// Output adaptor — subscribes to SpaceService events and shows popups.
/// Owns PopupWindow. Reads ConfigStore lazily per event for popup policy.
@MainActor
final class UserNotifier {

    private let configStore: ConfigStore
    private let popup: PopupWindow
    private var cancellables = Set<AnyCancellable>()

    init(configStore: ConfigStore, service: SpaceService, popup: PopupWindow) {
        self.configStore = configStore
        self.popup = popup

        service.onSpaceActivated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleSpaceActivated(name: event.name, reason: event.reason)
            }
            .store(in: &cancellables)

        service.onNotification
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.popup.show(message)
            }
            .store(in: &cancellables)
    }

    private func handleSpaceActivated(name: String, reason: ActivationReason) {
        switch reason {
        case .hotkey, .cli:
            if configStore.current.popups.whenSwitchingSpaces {
                popup.show(name)
            }
        case .configReload, .startup:
            popup.show(name)
        }
    }
}
