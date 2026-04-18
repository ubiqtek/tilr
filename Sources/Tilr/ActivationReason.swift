/// The reason a space activation or config apply was triggered.
/// Travels with every domain event so adaptors can apply the right policy.
enum ActivationReason {
    case hotkey       // user-initiated switch via keyboard
    case cli          // user-initiated switch via CLI command
    case configReload // system event — config was reloaded
    case startup      // system event — app just launched

    var logDescription: String {
        switch self {
        case .hotkey:       return "hotkey"
        case .cli:          return "cli"
        case .configReload: return "configReload"
        case .startup:      return "startup"
        }
    }
}
