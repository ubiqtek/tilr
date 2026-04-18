import AppKit
import HotKey
import OSLog

final class HotKeyManager {

    private var hotKeys: [HotKey] = []
    private let popup: PopupWindow
    private let config: TilrConfig
    private let stateStore: StateStore

    init(popup: PopupWindow, config: TilrConfig, stateStore: StateStore) {
        self.popup = popup
        self.config = config
        self.stateStore = stateStore
        register()
    }

    private func register() {
        let overview = HotKey(key: .space, modifiers: [.command, .option])
        overview.keyDownHandler = { [weak self] in
            Logger.hotkey.debug("cmd+opt+space fired (overview)")
            self?.popup.show("Tilr")
        }
        hotKeys.append(overview)

        let modifiers = parseModifiers(config.keyboardShortcuts.switchToSpace)
        for (spaceName, space) in config.spaces {
            guard let key = parseKey(space.id) else {
                Logger.hotkey.warning("Cannot parse key for space '\(spaceName, privacy: .public)' id='\(space.id, privacy: .public)' — skipping")
                continue
            }
            let combo = KeyCombo(key: key, modifiers: modifiers)
            let hotKey = HotKey(keyCombo: combo)
            hotKey.keyDownHandler = { [weak self] in
                guard let self else { return }
                Logger.hotkey.debug("Hotkey fired for space '\(spaceName, privacy: .public)'")
                self.stateStore.setActiveSpace(spaceName)
                if self.config.popups.whenSwitchingSpaces {
                    self.popup.show(spaceName)
                }
            }
            hotKeys.append(hotKey)
            Logger.hotkey.info("Registered \(self.config.keyboardShortcuts.switchToSpace, privacy: .public)+\(space.id, privacy: .public) for space '\(spaceName, privacy: .public)'")
        }
    }

    private func parseModifiers(_ string: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        let parts = string.lowercased().split(separator: "+").map(String.init)
        for part in parts {
            switch part {
            case "cmd":   flags.insert(.command)
            case "opt":   flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "ctrl":  flags.insert(.control)
            default:
                Logger.hotkey.warning("Unknown modifier '\(part, privacy: .public)' in '\(string, privacy: .public)'")
            }
        }
        return flags
    }

    private func parseKey(_ char: String) -> Key? {
        switch char.lowercased() {
        case "0": return .zero
        case "1": return .one
        case "2": return .two
        case "3": return .three
        case "4": return .four
        case "5": return .five
        case "6": return .six
        case "7": return .seven
        case "8": return .eight
        case "9": return .nine
        case "a": return .a
        case "b": return .b
        case "c": return .c
        case "d": return .d
        case "e": return .e
        case "f": return .f
        case "g": return .g
        case "h": return .h
        case "i": return .i
        case "j": return .j
        case "k": return .k
        case "l": return .l
        case "m": return .m
        case "n": return .n
        case "o": return .o
        case "p": return .p
        case "q": return .q
        case "r": return .r
        case "s": return .s
        case "t": return .t
        case "u": return .u
        case "v": return .v
        case "w": return .w
        case "x": return .x
        case "y": return .y
        case "z": return .z
        default:
            return nil
        }
    }
}
