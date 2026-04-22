import AppKit
import OSLog

@discardableResult
func contentWindow(forApp axApp: AXUIElement, bundleID: String) -> AXUIElement? {
    var windowRef: CFTypeRef?
    let mainResult = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
    if mainResult == .success, let windowRef {
        let candidate = windowRef as! AXUIElement
        if subrole(of: candidate) == kAXStandardWindowSubrole as String {
            return candidate
        }
    }

    var windowsRef: CFTypeRef?
    let windowsResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
    if windowsResult == .success, let windowsRef {
        let windows = windowsRef as! [AXUIElement]
        let seenSubroles = windows.compactMap { subrole(of: $0) }
        if let match = windows.first(where: { subrole(of: $0) == kAXStandardWindowSubrole as String }) {
            return match
        }
        Logger.layout.info("AX: no standard window for '\(bundleID, privacy: .public)' — saw subroles \(seenSubroles, privacy: .public)")
    }

    return nil
}

private func subrole(of window: AXUIElement) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &ref) == .success, let ref else {
        return nil
    }
    return ref as? String
}
