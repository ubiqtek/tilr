import AppKit
import Foundation
import OSLog

final class CommandHandler {
    private let startDate: Date
    private let configStore: ConfigStore
    private let service: SpaceService
    private weak var appWindowManager: AppWindowManager?
    private weak var popup: PopupWindow?

    init(configStore: ConfigStore, service: SpaceService, appWindowManager: AppWindowManager? = nil, popup: PopupWindow? = nil) {
        self.startDate = Date()
        self.configStore = configStore
        self.service = service
        self.appWindowManager = appWindowManager
        self.popup = popup
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
            let (activeSpace, spacesCount, fillScreenLast) = DispatchQueue.main.sync {
                (
                    service.activeSpace,
                    configStore.current.spaces.count,
                    appWindowManager?.fillScreenLastAppSnapshot() ?? [:]
                )
            }
            let data = StatusData(
                pid: ProcessInfo.processInfo.processIdentifier,
                uptimeSeconds: uptime,
                spacesCount: spacesCount,
                activeSpace: activeSpace,
                fillScreenLastApp: fillScreenLast
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

        case "identify-displays":
            let postSend: (() -> Void)? = { [weak self] in
                DispatchQueue.main.async {
                    self?.showIdentifyPopups()
                }
            }
            return (TilrResponse(ok: true, message: "Identifying displays"), postSend)

        case "apps-show", "apps-hide":
            guard let bundleID = request.bundleID, !bundleID.isEmpty else {
                return (TilrResponse(ok: false, error: "missing bundleID parameter"), nil)
            }
            let hidden = request.cmd == "apps-hide"
            let postSend: (() -> Void)? = {
                DispatchQueue.main.async {
                    if hidden {
                        hideApp(bundleID: bundleID)
                    } else {
                        showApp(bundleID: bundleID)
                    }
                }
            }
            let action = hidden ? "hide" : "show"
            return (TilrResponse(ok: true, message: "Queued \(action) for \(bundleID)"), postSend)

        default:
            return (TilrResponse(ok: false, error: "unknown command: \(request.cmd)"), nil)
        }
    }

    private func showIdentifyPopups() {
        let state = DisplayStateStore.load()
        let config = configStore.current
        for screen in NSScreen.screens {
            guard let uuid = displayUUID(for: screen),
                  let displayId = state.uuidToId[uuid] else { continue }
            let name = config.displays["\(displayId)"]?.name ?? screen.localizedName
            popup?.show("\(displayId) · \(name)", on: screen, duration: 3.0)
        }
    }
}
