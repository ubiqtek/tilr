import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?
    private var hotKeyManager: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.app.info("Tilr starting")
        let popup = PopupWindow()
        menuBarController = MenuBarController(popup: popup)
        hotKeyManager = HotKeyManager(popup: popup)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.app.info("Tilr shutting down")
        menuBarController = nil
        hotKeyManager = nil
    }
}
