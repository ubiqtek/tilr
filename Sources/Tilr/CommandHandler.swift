import Foundation
import OSLog

final class CommandHandler {
    private let startDate: Date
    var config: TilrConfig?
    var onConfigReloaded: ((TilrConfig) -> Void)?

    init() { self.startDate = Date() }

    /// Returns the response and an optional post-send action.
    /// The post-send action must be called *after* the response has been written
    /// to the socket so that side-effects (e.g. triggering a config-reload
    /// notification on the main thread) never race with the socket write.
    func handle(_ request: TilrRequest) -> (TilrResponse, postSend: (() -> Void)?) {
        switch request.cmd {
        case "status":
            let uptime = Int(Date().timeIntervalSince(startDate))
            let data = StatusData(
                pid: ProcessInfo.processInfo.processIdentifier,
                uptimeSeconds: uptime,
                spacesCount: config?.spaces.count ?? 0,
                activeSpace: nil
            )
            return (TilrResponse(ok: true, status: data), nil)
        case "reload-config":
            config = ConfigLoader.load()
            let count = config?.spaces.count ?? 0
            Logger.config.info("Reloaded config: \(count, privacy: .public) space(s)")
            let reloaded = config
            let postSend: (() -> Void)? = reloaded.map { cfg in { [weak self] in
                self?.onConfigReloaded?(cfg)
            }}
            return (TilrResponse(ok: true, message: "Reloaded \(count) space(s)"), postSend)
        default:
            return (TilrResponse(ok: false, error: "unknown command: \(request.cmd)"), nil)
        }
    }
}
