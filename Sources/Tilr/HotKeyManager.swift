import AppKit
import HotKey
import OSLog

final class HotKeyManager {

    private var hotKeys: [HotKey] = []
    private let popup: PopupWindow

    init(popup: PopupWindow) {
        self.popup = popup
        register()
    }

    private func register() {
        let statusKey = HotKey(key: .space, modifiers: [.command, .option])
        statusKey.keyDownHandler = { [weak self] in
            Logger.hotkey.info("cmd+opt+space fired")
            self?.popup.show("Tilr")
        }
        hotKeys.append(statusKey)
        Logger.hotkey.info("Registered cmd+opt+space")
    }
}
