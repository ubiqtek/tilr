import AppKit
import Combine
import HotKey
import OSLog

final class HotKeyManager {

    private var hotKeys: [HotKey] = []
    private let configStore: ConfigStore
    private let service: SpaceService
    private var cancellable: AnyCancellable?

    var moveAppHandler: ((String) -> Void)?

    init(configStore: ConfigStore, service: SpaceService) {
        self.configStore = configStore
        self.service = service
        register(config: configStore.current)

        cancellable = configStore.$current
            .dropFirst()  // skip the initial value — already registered above
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newConfig in
                // Only re-register if the hotkey-relevant parts of the config changed
                // (space names/IDs or keyboard shortcut modifiers). App membership
                // changes (e.g. moveCurrentApp) must not trigger re-registration.
                guard let self, self.hotkeyStructureChanged(newConfig) else { return }
                self.reregister(config: newConfig)
            }
    }

    private func hotkeyStructureChanged(_ newConfig: TilrConfig) -> Bool {
        let old = configStore.current
        guard old.keyboardShortcuts == newConfig.keyboardShortcuts else { return true }
        // Compare space names and their IDs (the parts that affect hotkey bindings).
        let oldSpaces = old.spaces.mapValues { $0.id }
        let newSpaces = newConfig.spaces.mapValues { $0.id }
        return oldSpaces != newSpaces
    }

    private func reregister(config: TilrConfig) {
        hotKeys.removeAll()
        register(config: config)
    }

    private func register(config: TilrConfig) {
        // Overview hotkey: cmd+opt+space → notification "Tilr"
        let overview = HotKey(key: .space, modifiers: [.command, .option])
        overview.keyDownHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.service.sendNotification("Tilr")
            }
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
                DispatchQueue.main.async {
                    self.service.switchToSpace(spaceName, reason: .hotkey)
                }
            }
            hotKeys.append(hotKey)
            Logger.hotkey.info("Registered \(config.keyboardShortcuts.switchToSpace, privacy: .public)+\(space.id, privacy: .public) for space '\(spaceName, privacy: .public)'")
            TilrLogger.shared.log("Registered \(config.keyboardShortcuts.switchToSpace)+\(space.id) for space '\(spaceName)'", category: "hotkey")
        }

        let moveModifiers = parseModifiers(config.keyboardShortcuts.moveAppToSpace)
        for (spaceName, space) in config.spaces {
            guard let key = parseKey(space.id) else { continue }
            let combo = KeyCombo(key: key, modifiers: moveModifiers)
            let hotKey = HotKey(keyCombo: combo)
            hotKey.keyDownHandler = { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.moveAppHandler?(spaceName)
                }
            }
            hotKeys.append(hotKey)
            Logger.hotkey.info("Registered \(config.keyboardShortcuts.moveAppToSpace, privacy: .public)+\(space.id, privacy: .public) → move app to '\(spaceName, privacy: .public)'")
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
