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
    private var statusOverlay: StatusOverlayWindow?
    private var stateCoordinator: StateCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.app.info("Tilr \(Version.full, privacy: .public) starting")
        TilrLogger.shared.log("Tilr v\(Version.full) starting", category: "app")

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

        // Initialize state from config and current system state
        let stateInit = StateInitializer(configStore: configStore)
        let (initialState, initCommand) = stateInit.initializeState()
        let initialSnapshot = TilrStateSnapshot(
            timestamp: Date(),
            command: initCommand,
            state: initialState
        )
        let coordinator = StateCoordinator(initialState: initialState, initialSnapshot: initialSnapshot)
        self.stateCoordinator = coordinator

        let svc = SpaceService(configStore: configStore)
        self.service = svc

        let popup = PopupWindow()
        let displayResolver = DisplayResolver()
        userNotifier      = UserNotifier(configStore: configStore, service: svc, popup: popup)
        menuBarController = MenuBarController(service: svc)
        hotKeyManager     = HotKeyManager(configStore: configStore, service: svc)
        appWindowManager  = AppWindowManager(configStore: configStore, service: svc, displayResolver: displayResolver)
        statusOverlay     = StatusOverlayWindow()

        hotKeyManager?.moveAppHandler = { [weak appWindowManager] spaceName in
            appWindowManager?.moveCurrentApp(toSpaceName: spaceName)
        }

        hotKeyManager?.statusOverlayHandler = { [weak self] in
            self?.toggleStatusOverlay()
        }

        let server = SocketServer(configStore: configStore, service: svc, appWindowManager: appWindowManager, popup: popup, stateCoordinator: coordinator)
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

    @MainActor
    private func toggleStatusOverlay() {
        let content = buildStatusContent()
        let focusedScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        statusOverlay?.toggle(content: content, on: focusedScreen)
    }

    @MainActor
    private func buildStatusContent() -> String {
        let displayState = DisplayStateStore.load()
        let displays = configStore.current.displays
        let currentSpace = service?.activeSpace ?? "—"

        let idWidth    = 2
        let nameWidth  = 18
        let spaceWidth = 13

        let connectedUUIDs = Set(NSScreen.screens.compactMap { displayUUID(for: $0) })

        let rows = displayState.uuidToId
            .filter { (uuid, _) in connectedUUIDs.contains(uuid) }
            .map { (_, intID) in intID }
            .sorted()
            .map { intID -> String in
                let name = displays["\(intID)"]?.name ?? "Display \(intID)"
                let idStr   = String(intID).padding(toLength: idWidth,   withPad: " ", startingAt: 0)
                let nameStr = name.padding(toLength: nameWidth,          withPad: " ", startingAt: 0)
                return "\(idStr)  \(nameStr)  \(currentSpace)"
            }

        let header = "ID".padding(toLength: idWidth,   withPad: " ", startingAt: 0) + "  "
                   + "Display".padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  "
                   + "Current Space"
        let sep    = String(repeating: "-", count: idWidth)   + "  "
                   + String(repeating: "-", count: nameWidth)  + "  "
                   + String(repeating: "-", count: spaceWidth)
        return ([header, sep] + rows).joined(separator: "\n")
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
