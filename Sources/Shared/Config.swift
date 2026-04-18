import Foundation

public struct TilrConfig: Codable {
    public var keyboardShortcuts: KeyboardShortcuts
    public var spaces: [String: SpaceDefinition]

    public init(keyboardShortcuts: KeyboardShortcuts = .default, spaces: [String: SpaceDefinition] = [:]) {
        self.keyboardShortcuts = keyboardShortcuts
        self.spaces = spaces
    }
}

public struct KeyboardShortcuts: Codable {
    public var switchToSpace: String
    public var moveAppToSpace: String

    public static let `default` = KeyboardShortcuts(
        switchToSpace: "cmd+opt",
        moveAppToSpace: "cmd+shift+opt"
    )

    public init(switchToSpace: String, moveAppToSpace: String) {
        self.switchToSpace = switchToSpace
        self.moveAppToSpace = moveAppToSpace
    }
}

public struct SpaceDefinition: Codable {
    public var id: String
    public var apps: [String]
    public var layout: Layout?

    public init(id: String, apps: [String] = [], layout: Layout? = nil) {
        self.id = id; self.apps = apps; self.layout = layout
    }
}

public struct Layout: Codable {
    public var type: LayoutType
    public var main: String?
    public var ratio: Double?

    public init(type: LayoutType, main: String? = nil, ratio: Double? = nil) {
        self.type = type; self.main = main; self.ratio = ratio
    }

    // Custom coding to encode ratio as a formatted decimal string so Yams
    // does not emit scientific notation (e.g. 6.5e-1 instead of 0.65).
    enum CodingKeys: String, CodingKey { case type, main, ratio }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(main, forKey: .main)
        if let ratio {
            let formatted = String(format: "%.4g", ratio)
            try container.encode(formatted, forKey: .ratio)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(LayoutType.self, forKey: .type)
        main = try container.decodeIfPresent(String.self, forKey: .main)
        // Accept both string ("0.65") and raw float from the YAML.
        if let str = try? container.decodeIfPresent(String.self, forKey: .ratio),
           let val = Double(str) {
            ratio = val
        } else {
            ratio = try container.decodeIfPresent(Double.self, forKey: .ratio)
        }
    }
}

public enum LayoutType: String, Codable {
    case sidebar
}

public extension TilrConfig {
    func derivedHotkey(for spaceName: String) -> String? {
        guard let space = spaces[spaceName] else { return nil }
        return "\(keyboardShortcuts.switchToSpace)+\(space.id)"
    }
}
