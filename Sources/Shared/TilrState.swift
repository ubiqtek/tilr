import Foundation

// MARK: - Command Enum

/// Represents the command that produced a state snapshot.
/// Each snapshot is the result of executing a specific command.
public enum Command: Codable, Sendable {
    case initialise
    case switchSpace(name: String)
    case hideApp(bundleId: String)
    case showApp(bundleId: String)
    case moveApp(bundleId: String, toSpaceName: String)
    case reloadConfig
    case custom(String) // For future extensibility

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case bundleId
        case toSpaceName
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "initialise":
            self = .initialise
        case "switchSpace":
            let name = try container.decode(String.self, forKey: .name)
            self = .switchSpace(name: name)
        case "hideApp":
            let bundleId = try container.decode(String.self, forKey: .bundleId)
            self = .hideApp(bundleId: bundleId)
        case "showApp":
            let bundleId = try container.decode(String.self, forKey: .bundleId)
            self = .showApp(bundleId: bundleId)
        case "moveApp":
            let bundleId = try container.decode(String.self, forKey: .bundleId)
            let toSpaceName = try container.decode(String.self, forKey: .toSpaceName)
            self = .moveApp(bundleId: bundleId, toSpaceName: toSpaceName)
        case "reloadConfig":
            self = .reloadConfig
        default:
            let value = try container.decode(String.self, forKey: .value)
            self = .custom(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .initialise:
            try container.encode("initialise", forKey: .type)
        case .switchSpace(let name):
            try container.encode("switchSpace", forKey: .type)
            try container.encode(name, forKey: .name)
        case .hideApp(let bundleId):
            try container.encode("hideApp", forKey: .type)
            try container.encode(bundleId, forKey: .bundleId)
        case .showApp(let bundleId):
            try container.encode("showApp", forKey: .type)
            try container.encode(bundleId, forKey: .bundleId)
        case .moveApp(let bundleId, let toSpaceName):
            try container.encode("moveApp", forKey: .type)
            try container.encode(bundleId, forKey: .bundleId)
            try container.encode(toSpaceName, forKey: .toSpaceName)
        case .reloadConfig:
            try container.encode("reloadConfig", forKey: .type)
        case .custom(let value):
            try container.encode("custom", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    /// Human-readable description of the command
    public var description: String {
        switch self {
        case .initialise:
            return "initialise"
        case .switchSpace(let name):
            return "switchSpace(\(name))"
        case .hideApp(let bundleId):
            return "hideApp(\(bundleId))"
        case .showApp(let bundleId):
            return "showApp(\(bundleId))"
        case .moveApp(let bundleId, let toSpaceName):
            return "moveApp(\(bundleId), \(toSpaceName))"
        case .reloadConfig:
            return "reloadConfig"
        case .custom(let value):
            return "custom(\(value))"
        }
    }
}

// MARK: - Domain Types

/// Visibility state of an app within a space.
public enum AppDisplayState: String, Codable, Sendable {
    case visible
    case hidden
}

/// Represents a display (monitor) and its spaces.
public struct Display: Codable, Sendable {
    public let id: Int
    public let uuid: String
    public let name: String
    public var spaces: [Space]
    /// ID of the currently active space on this display, if any.
    public var activeSpaceId: String?

    public init(id: Int, uuid: String, name: String, spaces: [Space] = [], activeSpaceId: String? = nil) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.spaces = spaces
        self.activeSpaceId = activeSpaceId
    }

    /// Convenience: get the currently active space.
    public var activeSpace: Space? {
        guard let id = activeSpaceId else { return nil }
        return spaces.first { $0.id == id }
    }
}

/// Represents a workspace (space) and its visible apps.
public struct Space: Codable, Sendable {
    public let id: String
    public let name: String
    public var apps: [App]
    /// Bundle IDs of apps currently visible in this space.
    public var visibleAppIds: Set<String>

    public init(id: String, name: String, apps: [App] = [], visibleAppIds: Set<String> = []) {
        self.id = id
        self.name = name
        self.apps = apps
        self.visibleAppIds = visibleAppIds
    }

    /// Convenience: check if an app is visible in this space.
    public func isVisible(_ app: App) -> Bool {
        visibleAppIds.contains(app.id)
    }

    /// Convenience: get all visible apps.
    public var visibleApps: [App] {
        apps.filter { visibleAppIds.contains($0.id) }
    }
}

/// Represents an application.
public struct App: Codable, Sendable {
    public let id: String // bundle ID, e.g. "com.apple.dt.Xcode"
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Execution outcome for a single action.
public struct ActionOutcome: Codable, Sendable {
    public enum Result: String, Codable, Sendable {
        case succeeded
        case failed
        case timeout
    }

    public let action: String
    public let result: Result
    public let errorMessage: String?

    public init(action: String, result: Result, errorMessage: String? = nil) {
        self.action = action
        self.result = result
        self.errorMessage = errorMessage
    }
}

/// Mutable current state of Tilr.
public struct TilrState: Codable, Sendable {
    public var displays: [Display]

    public init(displays: [Display] = []) {
        self.displays = displays
    }

    /// Convenience: get a display by ID.
    public func display(byId id: Int) -> Display? {
        displays.first { $0.id == id }
    }

    /// Convenience: get all apps across all spaces.
    public var allApps: [App] {
        displays.flatMap { $0.spaces.flatMap { $0.apps } }
    }
}

/// Immutable snapshot of state at a moment in time, for audit trail and IPC.
public struct TilrStateSnapshot: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let command: Command?
    public let state: TilrState
    public let plan: String? // Description of what was planned (for future use)
    public let outcomes: [ActionOutcome]?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        command: Command? = nil,
        state: TilrState,
        plan: String? = nil,
        outcomes: [ActionOutcome]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.command = command
        self.state = state
        self.plan = plan
        self.outcomes = outcomes
    }
}
