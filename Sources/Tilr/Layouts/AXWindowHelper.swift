import AppKit
import OSLog

/// Sets the position and size of the main window of a running application
/// via the Accessibility API. Returns false and logs if the operation fails.
@discardableResult
func setWindowFrame(bundleID: String, frame: CGRect) -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        Logger.layout.info("AX: app '\(bundleID, privacy: .public)' not running — skipping")
        return false
    }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    var windowRef: CFTypeRef?
    let windowResult = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
    guard windowResult == .success, let windowRef else {
        Logger.layout.info("AX: no main window for '\(bundleID, privacy: .public)' (err \(windowResult.rawValue, privacy: .public)) — skipping")
        return false
    }

    let axWindow = windowRef as! AXUIElement

    var point = frame.origin
    guard let posValue = AXValueCreate(.cgPoint, &point) else { return false }
    let posResult = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
    if posResult != .success {
        Logger.layout.info("AX: set position failed for '\(bundleID, privacy: .public)' (err \(posResult.rawValue, privacy: .public))")
    }

    var size = frame.size
    guard let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
    let sizeResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
    if sizeResult != .success {
        Logger.layout.info("AX: set size failed for '\(bundleID, privacy: .public)' (err \(sizeResult.rawValue, privacy: .public))")
    }

    return posResult == .success && sizeResult == .success
}
