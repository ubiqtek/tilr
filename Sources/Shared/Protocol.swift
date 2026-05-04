import Foundation

public struct TilrRequest: Codable {
    public let cmd: String
    public let bundleID: String?

    public init(cmd: String, bundleID: String? = nil) {
        self.cmd = cmd
        self.bundleID = bundleID
    }
}

public struct StatusData: Codable {
    public let pid: Int32
    public let uptimeSeconds: Int
    public let spacesCount: Int
    public let activeSpace: String?
    public let fillScreenLastApp: [String: String]?

    public init(pid: Int32, uptimeSeconds: Int, spacesCount: Int, activeSpace: String?, fillScreenLastApp: [String: String]? = nil) {
        self.pid = pid; self.uptimeSeconds = uptimeSeconds
        self.spacesCount = spacesCount; self.activeSpace = activeSpace
        self.fillScreenLastApp = fillScreenLastApp
    }
}

public struct TilrResponse: Codable {
    public let ok: Bool
    public let status: StatusData?
    public let message: String?
    public let error: String?
    public init(ok: Bool, status: StatusData? = nil, message: String? = nil, error: String? = nil) {
        self.ok = ok; self.status = status; self.message = message; self.error = error
    }
}

public struct TilrStateRequest: Codable, Sendable {
    public let action: String // "view", "export", or "history"

    public init(action: String) {
        self.action = action
    }
}

public struct TilrStateResponse: Codable, Sendable {
    public let ok: Bool
    public let snapshot: TilrStateSnapshot?
    public let error: String?

    public init(ok: Bool, snapshot: TilrStateSnapshot? = nil, error: String? = nil) {
        self.ok = ok
        self.snapshot = snapshot
        self.error = error
    }
}

public enum TilrPaths {
    public static var socket: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/tilr", isDirectory: true)
            .appendingPathComponent("tilr.sock", isDirectory: false)
    }
}
