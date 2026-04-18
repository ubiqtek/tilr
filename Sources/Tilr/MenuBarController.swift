import AppKit
import Combine
import OSLog

final class MenuBarController {

    private let statusItem: NSStatusItem
    private let popup: PopupWindow
    private var cancellable: AnyCancellable?

    init(popup: PopupWindow, stateStore: StateStore) {
        self.popup = popup
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Tilr"
        statusItem.menu = buildMenu()

        cancellable = stateStore.$activeSpace
            .receive(on: DispatchQueue.main)
            .sink { [weak self] space in
                if let space {
                    self?.statusItem.button?.title = "[\(space)]"
                } else {
                    self?.statusItem.button?.title = "Tilr"
                }
            }

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
