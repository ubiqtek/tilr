import AppKit

@MainActor
protocol LayoutStrategy {
    func apply(name: String, space: SpaceDefinition, config: TilrConfig, screen: NSScreen)
}
