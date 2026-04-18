import Foundation
import OSLog

final class ConfigLoader {
    static func load() -> TilrConfig? {
        do {
            let config = try ConfigStore.load()
            Logger.config.info("Loaded \(config.spaces.count, privacy: .public) space(s)")
            return config
        } catch {
            Logger.config.error("Config load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
