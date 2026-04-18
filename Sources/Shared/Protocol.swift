import Foundation

public struct TilrRequest: Codable {
    public let cmd: String
    public init(cmd: String) { self.cmd = cmd }
}

public struct StatusData: Codable {
    public let pid: Int32
    public let uptimeSeconds: Int
    public let spacesCount: Int
    public let activeSpace: String?
    public init(pid: Int32, uptimeSeconds: Int, spacesCount: Int, activeSpace: String?) {
        self.pid = pid; self.uptimeSeconds = uptimeSeconds
        self.spacesCount = spacesCount; self.activeSpace = activeSpace
    }
}

public struct TilrResponse: Codable {
    public let ok: Bool
    public let status: StatusData?
    public let error: String?
    public init(ok: Bool, status: StatusData? = nil, error: String? = nil) {
        self.ok = ok; self.status = status; self.error = error
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
