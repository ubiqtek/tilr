import Foundation
import OSLog

final class CommandHandler {
    private let startDate: Date
    private let configStore: ConfigStore
    private let service: SpaceService

    init(configStore: ConfigStore, service: SpaceService) {
        self.startDate = Date()
        self.configStore = configStore
        self.service = service
    }

    /// Returns the response and an optional post-send action.
    /// The post-send action must be called *after* the response has been written
    /// to the socket so that side-effects (e.g. triggering a config-reload
    /// notification on the main thread) never race with the socket write.
    /// Called from the socket background queue — hops to main when needed.
    func handle(_ request: TilrRequest) -> (TilrResponse, postSend: (() -> Void)?) {
        switch request.cmd {
        case "status":
            let uptime = Int(Date().timeIntervalSince(startDate))
            // Read @MainActor state synchronously from the background queue.
            let (activeSpace, spacesCount) = DispatchQueue.main.sync {
                (service.activeSpace, configStore.current.spaces.count)
            }
            let data = StatusData(
                pid: ProcessInfo.processInfo.processIdentifier,
                uptimeSeconds: uptime,
                spacesCount: spacesCount,
                activeSpace: activeSpace
            )
            return (TilrResponse(ok: true, status: data), nil)

        case "reload-config":
            // Perform the reload on main so @Published fires on the right thread,
            // then read the resulting count while still on main.
            let count = DispatchQueue.main.sync { () -> Int in
                configStore.reload()
                return configStore.current.spaces.count
            }
            Logger.config.info("Reloaded config: \(count, privacy: .public) space(s)")
            let postSend: (() -> Void)? = { [weak self] in
                DispatchQueue.main.async {
                    self?.service.applyConfig(reason: .configReload)
                }
            }
            return (TilrResponse(ok: true, message: "Reloaded \(count) space(s)"), postSend)

        default:
            return (TilrResponse(ok: false, error: "unknown command: \(request.cmd)"), nil)
        }
    }
}
