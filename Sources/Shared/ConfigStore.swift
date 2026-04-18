import Foundation
import Yams

public struct ConfigStore {
    public static func load() throws -> TilrConfig {
        let url = ConfigPaths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            let default_ = TilrConfig()
            try save(default_)
            return default_
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try YAMLDecoder().decode(TilrConfig.self, from: raw)
    }

    public static func save(_ config: TilrConfig) throws {
        let url = ConfigPaths.configFile
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoded = try YAMLEncoder().encode(config)
        try encoded.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func rawYAML() throws -> String {
        let url = ConfigPaths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
