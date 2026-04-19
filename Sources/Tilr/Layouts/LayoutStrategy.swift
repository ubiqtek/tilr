import AppKit

protocol LayoutStrategy {
    func apply(space: SpaceDefinition, config: TilrConfig, screen: NSScreen)
}
