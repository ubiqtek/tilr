import Foundation

public enum ConfigPaths {
    public static var configFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tilr/config.yaml")
    }
}
