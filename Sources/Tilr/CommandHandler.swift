import Foundation

final class CommandHandler {
    private let startDate: Date
    init() { self.startDate = Date() }

    func handle(_ request: TilrRequest) -> TilrResponse {
        switch request.cmd {
        case "status":
            let uptime = Int(Date().timeIntervalSince(startDate))
            let data = StatusData(
                pid: ProcessInfo.processInfo.processIdentifier,
                uptimeSeconds: uptime,
                spacesCount: 0,
                activeSpace: nil
            )
            return TilrResponse(ok: true, status: data)
        default:
            return TilrResponse(ok: false, error: "unknown command: \(request.cmd)")
        }
    }
}
