import Foundation

/// Renders TilrState as ASCII tree or JSON.
public class StateFormatter {
    public init() {}

    /// Format state as a human-readable ASCII tree.
    public func formatAsTree(_ snapshot: TilrStateSnapshot) -> String {
        let state = snapshot.state
        var lines: [String] = []

        lines.append("TilrState")
        for (displayIdx, display) in state.displays.enumerated() {
            let isLast = displayIdx == state.displays.count - 1
            let prefix = isLast ? "└─" : "├─"
            let activeLabel = display.activeSpaceId.map { " [active space: \($0)]" } ?? ""
            lines.append("\(prefix) Display \"\(display.name)\" (id: \(display.id), uuid: \(display.uuid))\(activeLabel)")

            let spacePrefix = isLast ? "   " : "│  "
            for (spaceIdx, space) in display.spaces.enumerated() {
                let spaceIsLast = spaceIdx == display.spaces.count - 1
                let spaceSymbol = spaceIsLast ? "└─" : "├─"
                let isActiveSpace = display.activeSpaceId == space.id ? " [ACTIVE]" : ""
                lines.append("\(spacePrefix)\(spaceSymbol) Space \"\(space.name)\"\(isActiveSpace)")

                let appPrefix = spacePrefix + (spaceIsLast ? "   " : "│  ")
                for (appIdx, app) in space.apps.enumerated() {
                    let appIsLast = appIdx == space.apps.count - 1
                    let appSymbol = appIsLast ? "└─" : "├─"
                    let visibility = space.visibleAppIds.contains(app.id) ? "VISIBLE" : "HIDDEN"
                    lines.append("\(appPrefix)\(appSymbol) App \"\(app.name)\" (\(app.id)) [\(visibility)]")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Format state as JSON.
    public func formatAsJSON(_ snapshot: TilrStateSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Format snapshot metadata (id, timestamp, command, etc).
    public func formatMetadata(_ snapshot: TilrStateSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = formatter.string(from: snapshot.timestamp)

        var lines: [String] = []
        lines.append("Snapshot ID: \(snapshot.id)")
        lines.append("Timestamp: \(timestamp)")
        if let command = snapshot.command {
            lines.append("Command: \(command.description)")
        }
        if let plan = snapshot.plan {
            lines.append("Plan: \(plan)")
        }
        if let outcomes = snapshot.outcomes, !outcomes.isEmpty {
            lines.append("Outcomes:")
            for outcome in outcomes {
                let resultStr = outcome.result.rawValue
                let errorStr = outcome.errorMessage.map { " — \($0)" } ?? ""
                lines.append("  - \(outcome.action): \(resultStr)\(errorStr)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
