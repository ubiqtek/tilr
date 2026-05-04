import Foundation

public enum Version {
    /// Full version string, e.g. "0.0.1-local-afe4-b7c2" or "0.0.1".
    public static var full: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// Base version without suffix, e.g. "0.0.1".
    public static var base: String {
        full.split(separator: "-").first.map(String.init) ?? full
    }

    /// Build timestamp from Info.plist (set by the build phase via xcconfig).
    public static var buildDate: String {
        Bundle.main.infoDictionary?["TILRBuildDate"] as? String ?? "unknown"
    }

    /// True if this is a local dev build.
    public static var isLocal: Bool { full.contains("-local-") }

    /// Bundle ID from Info.plist.
    public static var bundleID: String {
        Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "unknown"
    }

    /// Multi-line info block for `--version` output and About overlay.
    public static var info: String {
        """
        \(full)
        built \(buildDate)
        \(bundleID)
        """
    }
}
