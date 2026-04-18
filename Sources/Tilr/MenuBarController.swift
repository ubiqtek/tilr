import AppKit
import OSLog

final class MenuBarController {

    private let statusItem: NSStatusItem
    private let popup: PopupWindow

    init(popup: PopupWindow) {
        self.popup = popup
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Tilr"
        statusItem.menu = buildMenu()
        Logger.menuBar.info("Menu bar ready")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let helpItem = NSMenuItem(title: "Help", action: #selector(showHelp), keyEquivalent: "")
        helpItem.target = self
        helpItem.isEnabled = true
        menu.addItem(helpItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Tilr", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func showHelp() {
        popup.show("⌘⌥Space   Status", duration: 3.0)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
