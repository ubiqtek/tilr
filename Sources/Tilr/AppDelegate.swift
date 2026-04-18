import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?
    private var hotKeyManager: HotKeyManager?
    private let socketServer = SocketServer()
    private let stateStore = StateStore()
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private var config: TilrConfig?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.app.info("Tilr starting")
        socketServer.start()
        let loadedConfig = ConfigLoader.load() ?? TilrConfig()
        config = loadedConfig
        socketServer.commandHandler.config = config
        let popup = PopupWindow()
        menuBarController = MenuBarController(popup: popup, stateStore: stateStore)
        hotKeyManager = HotKeyManager(popup: popup, config: loadedConfig, stateStore: stateStore)
        socketServer.commandHandler.onConfigReloaded = { [weak self, weak popup] newConfig in
            DispatchQueue.main.async {
                self?.activateDefaultSpace(config: newConfig, popup: popup)
            }
        }
        activateDefaultSpace(config: loadedConfig, popup: popup)
        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.app.info("Tilr shutting down")
        socketServer.stop()
        menuBarController = nil
        hotKeyManager = nil
    }

    private func activateDefaultSpace(config: TilrConfig, popup: PopupWindow?) {
        guard let ref = config.displays["1"]?.defaultSpace else {
            popup?.show("↺ Config")
            Logger.app.info("Config reloaded — no default space configured for display 1")
            return
        }
        let spaceName: String?
        if ref.count == 1 {
            spaceName = config.spaces.first(where: { $0.value.id == ref })?.key
        } else {
            spaceName = config.spaces[ref] != nil ? ref : nil
        }
        guard let name = spaceName else {
            Logger.app.warning("Default space '\(ref, privacy: .public)' for display 1 not found in config")
            popup?.show("↺ Config")
            return
        }
        stateStore.setActiveSpace(name)
        popup?.show(name)
        Logger.app.info("Activated default space '\(name, privacy: .public)' for display 1")
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let queue = DispatchQueue(label: "io.ubiqtek.tilr.signals")

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        intSource.setEventHandler { [weak self] in
            self?.socketServer.stop()
            exit(0)
        }
        intSource.resume()
        sigintSource = intSource

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termSource.setEventHandler { [weak self] in
            self?.socketServer.stop()
            exit(0)
        }
        termSource.resume()
        sigtermSource = termSource
    }
}
