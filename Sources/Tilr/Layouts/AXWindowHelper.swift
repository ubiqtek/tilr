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

/// Sets or clears the hidden state of all running instances of an app.
/// The hide path is guarded by `isHidden`. The unhide path is not — this
/// matches the Hammerspoon reference implementation and produces more
/// reliable unhide behaviour in practice. After the initial call, schedules
/// up to 2 retries (~300 ms apart) if the actual state doesn't match the
/// intent — some apps (Ghostty, Zen, Marq) don't honour the first
/// hide/unhide AppleEvent reliably.
@MainActor
func setAppHidden(bundleID: String, hidden: Bool) {
    let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    for app in instances {
        if hidden {
            guard !app.isHidden else { continue }
            let wasHidden = app.isHidden
            app.hide()
            Logger.layout.info("hide-diag: \(bundleID, privacy: .public) intended=hidden isHidden_before=\(wasHidden, privacy: .public) isHidden_after=\(app.isHidden, privacy: .public)")
        } else {
            let wasHidden = app.isHidden
            app.unhide()
            Logger.layout.info("hide-diag: \(bundleID, privacy: .public) intended=visible isHidden_before=\(wasHidden, privacy: .public) isHidden_after=\(app.isHidden, privacy: .public)")
        }
        scheduleHiddenStateRetry(bundleID: bundleID, desiredHidden: hidden, attemptsRemaining: 2)
    }
}

@MainActor
private func scheduleHiddenStateRetry(bundleID: String, desiredHidden: Bool, attemptsRemaining: Int) {
    guard attemptsRemaining > 0 else { return }
    let isFinalAttempt = attemptsRemaining == 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let app = apps.first else { return }

        let attemptNumber = 3 - attemptsRemaining
        let current = app.isHidden
        Logger.layout.info(
            "hide-diag retry\(attemptNumber, privacy: .public): \(bundleID, privacy: .public) isHidden=\(current, privacy: .public) intended=\(desiredHidden ? "hidden" : "visible", privacy: .public) willRetry=\(current != desiredHidden, privacy: .public)"
        )
        if current == desiredHidden { return }

        if isFinalAttempt {
            setHiddenViaSystemEvents(bundleID: bundleID, hidden: desiredHidden)
        } else if desiredHidden {
            app.hide()
        } else {
            app.unhide()
        }
        scheduleHiddenStateRetry(bundleID: bundleID, desiredHidden: desiredHidden, attemptsRemaining: attemptsRemaining - 1)
    }
}

private func setHiddenViaSystemEvents(bundleID: String, hidden: Bool) {
    guard let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName else { return }
    let escapedName = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let visibleValue = hidden ? "false" : "true"
    let source = "tell application \"System Events\" to set visible of process \"\(escapedName)\" to \(visibleValue)"

    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", source]
    do {
        try task.run()
    } catch {
        // Fire-and-forget last-resort; swallow errors silently.
    }
}
