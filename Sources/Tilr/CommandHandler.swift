import Foundation
import OSLog

final class CommandHandler {
    private let startDate: Date
    var config: TilrConfig?

    init() { self.startDate = Date() }

    func handle(_ request: TilrRequest) -> TilrResponse {
        switch request.cmd {
        case "status":
            let uptime = Int(Date().timeIntervalSince(startDate))
            let data = StatusData(
                pid: ProcessInfo.processInfo.processIdentifier,
                uptimeSeconds: uptime,
                spacesCount: config?.spaces.count ?? 0,
                activeSpace: nil
            )
            return TilrResponse(ok: true, status: data)
        case "reload-config":
            config = ConfigLoader.load()
            let count = config?.spaces.count ?? 0
            Logger.config.info("Reloaded config: \(count, privacy: .public) space(s)")
            return TilrResponse(ok: true, message: "Reloaded \(count) space(s)")
        default:
            return TilrResponse(ok: false, error: "unknown command: \(request.cmd)")
        }
    }
}
