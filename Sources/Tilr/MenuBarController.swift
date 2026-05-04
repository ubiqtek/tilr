import AppKit
import Combine
import OSLog

@MainActor
final class MenuBarController {

    private let statusItem: NSStatusItem
    private var cancellable: AnyCancellable?
    private var aboutOverlay: AboutOverlayWindow?

    init(service: SpaceService) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Tilr"
        statusItem.menu = buildMenu()

        cancellable = service.onSpaceActivated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.statusItem.button?.title = "[\(event.name)]"
            }

        Logger.menuBar.info("Menu bar ready")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Tilr\u{2026}", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.isEnabled = true
        menu.addItem(aboutItem)
        menu.addItem(.separator())
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

    @objc private func showAbout() {
        let overlay = AboutOverlayWindow()
        self.aboutOverlay = overlay
        let screen = NSScreen.main ?? NSScreen.screens[0]
        overlay.show(on: screen)
    }

    @objc private func showHelp() {
        // Help is shown via the menu bar; no popup reference needed here.
        // If a future help popup is needed, wire through SpaceService.onNotification.
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
