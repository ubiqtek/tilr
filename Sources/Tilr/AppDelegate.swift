import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let configStore = ConfigStore()
    private var service: SpaceService?
    private var userNotifier: UserNotifier?
    private var menuBarController: MenuBarController?
    private var hotKeyManager: HotKeyManager?
    private var appWindowManager: AppWindowManager?
    private var socketServer: SocketServer?
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.app.info("Tilr starting")
        TilrLogger.shared.log("Tilr starting", category: "app")

        let axTrusted: Bool
        if configStore.current.accessibility.promptOnLaunch {
            let axOptions = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            axTrusted = AXIsProcessTrustedWithOptions(axOptions)
        } else {
            axTrusted = AXIsProcessTrusted()
            if !axTrusted {
                Logger.windows.warning("AX permission not granted — grant access in System Settings → Privacy & Security → Accessibility")
                TilrLogger.shared.log("AX permission not granted — grant access in System Settings → Privacy & Security → Accessibility", category: "windows")
            }
        }
        Logger.windows.info("AX trusted: \(axTrusted, privacy: .public)")
        TilrLogger.shared.log("AX trusted: \(axTrusted)", category: "windows")

        let svc = SpaceService(configStore: configStore)
        self.service = svc

        let popup = PopupWindow()
        userNotifier      = UserNotifier(configStore: configStore, service: svc, popup: popup)
        menuBarController = MenuBarController(service: svc)
        hotKeyManager     = HotKeyManager(configStore: configStore, service: svc)
        appWindowManager  = AppWindowManager(configStore: configStore, service: svc)

        hotKeyManager?.moveAppHandler = { [weak appWindowManager] spaceName in
            appWindowManager?.moveCurrentApp(toSpaceName: spaceName)
        }

        let server = SocketServer(configStore: configStore, service: svc, appWindowManager: appWindowManager)
        self.socketServer = server
        server.start()

        svc.applyConfig(reason: .startup)

        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.app.info("Tilr shutting down")
        TilrLogger.shared.log("Tilr shutting down", category: "app")
        socketServer?.stop()
        menuBarController = nil
        hotKeyManager = nil
        appWindowManager = nil
        userNotifier = nil
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let queue = DispatchQueue(label: "io.ubiqtek.tilr.signals")

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        intSource.setEventHandler { [weak self] in
            self?.socketServer?.stop()
            exit(0)
        }
        intSource.resume()
        sigintSource = intSource

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termSource.setEventHandler { [weak self] in
            self?.socketServer?.stop()
            exit(0)
        }
        termSource.resume()
        sigtermSource = termSource
    }
}
