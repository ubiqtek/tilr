import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?
    private var hotKeyManager: HotKeyManager?
    private let socketServer = SocketServer()
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private var config: TilrConfig?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.app.info("Tilr starting")
        socketServer.start()
        config = ConfigLoader.load()
        socketServer.commandHandler.config = config
        let popup = PopupWindow()
        menuBarController = MenuBarController(popup: popup)
        hotKeyManager = HotKeyManager(popup: popup)
        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.app.info("Tilr shutting down")
        socketServer.stop()
        menuBarController = nil
        hotKeyManager = nil
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
