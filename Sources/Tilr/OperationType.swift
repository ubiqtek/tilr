/// Describes the kind of operation that triggered a layout apply.
/// Layout strategies branch on this to apply the correct show/hide/frame policy.
enum OperationType {
    /// The user switched to a space (hotkey, CLI, startup, etc.).
    /// All apps in the space should be shown/arranged per normal layout rules.
    case spaceSwitch(spaceName: String)

    /// A specific app was moved into the target space from another space (or no space).
    /// Only the moved app should be repositioned; competitors should be hidden first.
    case windowMove(movedBundleID: String, sourceSpace: String?, targetSpace: String)
}
