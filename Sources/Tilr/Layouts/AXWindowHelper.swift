import AppKit
import OSLog

/// Sets the position and size of the main window of a running application
/// via the Accessibility API. Returns false and logs if the operation fails.
@discardableResult
func setWindowFrame(bundleID: String, frame: CGRect) -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        Logger.layout.info("AX: app '\(bundleID, privacy: .public)' not running — skipping")
        TilrLogger.shared.log("setWindowFrame: '\(bundleID)' not running", category: "layout")
        return false
    }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    guard let axWindow = contentWindow(forApp: axApp, bundleID: bundleID) else {
        Logger.layout.info("AX: no content window for '\(bundleID, privacy: .public)' — skipping")
        TilrLogger.shared.log("setWindowFrame: no content window for '\(bundleID)'", category: "layout")
        return false
    }
    Logger.layout.info("AX: setting '\(bundleID, privacy: .public)' to x=\(frame.origin.x) y=\(frame.origin.y) w=\(frame.size.width) h=\(frame.size.height)")

    // Size → Position: mirrors hs.window:setFrameWithWorkarounds to defeat
    // stubborn apps that clamp width when moved before shrinking. The trailing
    // Size call is omitted — it causes Zen Browser to snap its origin back to x=0.
    // Step 1: set size while window is still at its current on-screen position.
    var size1 = frame.size
    guard let sizeValue1 = AXValueCreate(.cgSize, &size1) else { return false }
    let sizeResult1 = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue1)
    Logger.layout.info("AX: set size for '\(bundleID, privacy: .public)' result=\(sizeResult1.rawValue, privacy: .public)")

    // Step 2: read back the actual size — app may have refused to shrink.
    var sizeRef1: CFTypeRef?
    if AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef1) == .success,
       let sizeRef1 {
        var readBack = CGSize.zero
        AXValueGetValue(sizeRef1 as! AXValue, .cgSize, &readBack)
        if readBack.width * readBack.height > frame.size.width * frame.size.height {
            Logger.layout.info("AX: app '\(bundleID, privacy: .public)' refused shrink — requested w=\(frame.size.width, privacy: .public) h=\(frame.size.height, privacy: .public), got w=\(readBack.width, privacy: .public) h=\(readBack.height, privacy: .public), accepting actual")
        }
    }
    // If readback fails, proceed with the requested size — best effort.

    // Step 3: move to the target origin.
    var point = frame.origin
    guard let posValue = AXValueCreate(.cgPoint, &point) else { return false }
    let posResult = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
    if posResult != .success {
        Logger.layout.info("AX: set position failed for '\(bundleID, privacy: .public)' (err \(posResult.rawValue, privacy: .public))")
    }

    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    let posReadResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
    let sizeReadResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
    if posReadResult == .success, let posRef,
       sizeReadResult == .success, let sizeRef {
        var actualPoint = CGPoint.zero
        var actualSize = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &actualPoint)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &actualSize)
        Logger.layout.info("AX: post-set frame for '\(bundleID, privacy: .public)' is x=\(actualPoint.x, privacy: .public) y=\(actualPoint.y, privacy: .public) w=\(actualSize.width, privacy: .public) h=\(actualSize.height, privacy: .public)")
    } else {
        Logger.layout.info("AX: post-set frame for '\(bundleID, privacy: .public)' unreadable (pos=\(posReadResult.rawValue, privacy: .public), size=\(sizeReadResult.rawValue, privacy: .public))")
    }

    TilrLogger.shared.log("setWindowFrame: '\(bundleID)' pos=\(posResult.rawValue) size=\(sizeResult1.rawValue)", category: "layout")
    return posResult == .success && sizeResult1 == .success
}

/// Tracks the most recent intended visible state per bundle ID.
/// `scheduleHiddenStateRetry` checks this to self-cancel if a subsequent
/// space switch has reversed the intent (e.g. Coding shows Marq after Scratch hid it).
@MainActor var intendedVisibleState: [String: Bool] = [:]

/// Hides all running instances of an app. Tries AppKit `app.hide()` first,
/// then falls back to osascript via `setHiddenViaOsascript()` if state drifts
/// during the retry chain. Records intent in `intendedVisibleState` so retry
/// chains self-cancel if a subsequent space switch reverses the intent.
/// Schedules up to 5 retries at 0.3s intervals.
@MainActor
func hideApp(bundleID: String) {
    intendedVisibleState[bundleID] = false
    let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    for app in instances {
        let isVisible = !app.isHidden
        Logger.windows.info("[hide] hideApp: '\(bundleID, privacy: .public)' isVisible=\(isVisible)")
        TilrLogger.shared.log("[hide] hideApp: '\(bundleID)' isVisible=\(isVisible)", category: "windows")
        Logger.windows.info("[hide] AppKit: calling app.hide()")
        TilrLogger.shared.log("[hide] AppKit: calling app.hide()", category: "windows")
        app.hide()
        scheduleHiddenStateRetry(bundleID: bundleID, desiredVisible: false, attemptsRemaining: 5)
    }
}

/// Shows all running instances of an app via AppKit unhide.
/// Records intent in `intendedVisibleState` so retry chains self-cancel if a
/// subsequent space switch reverses the intent.
@MainActor
func showApp(bundleID: String) {
    intendedVisibleState[bundleID] = true
    let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    for app in instances {
        let isVisible = !app.isHidden
        Logger.windows.info("[show] showApp: '\(bundleID, privacy: .public)' isVisible=\(isVisible)")
        TilrLogger.shared.log("[show] showApp: '\(bundleID)' isVisible=\(isVisible)", category: "windows")
        Logger.windows.info("[show] AppKit: calling app.unhide()")
        TilrLogger.shared.log("[show] AppKit: calling app.unhide()", category: "windows")
        app.unhide()
        scheduleHiddenStateRetry(bundleID: bundleID, desiredVisible: true, attemptsRemaining: 5)
    }
}

@MainActor
private func scheduleHiddenStateRetry(bundleID: String, desiredVisible: Bool, attemptsRemaining: Int) {
    guard attemptsRemaining > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        let tag = desiredVisible ? "[show]" : "[hide]"
        guard intendedVisibleState[bundleID] == desiredVisible else {
            let currentIntent = intendedVisibleState[bundleID]
            let msg = "\(tag) INTERRUPT: intent changed to \(String(describing: currentIntent)) (was \(desiredVisible)), cancelling retry chain"
            Logger.windows.info("\(msg, privacy: .public)")
            TilrLogger.shared.log(msg, category: "windows")
            return
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let app = apps.first else { return }
        Logger.windows.info("\(tag, privacy: .public) retry: '\(bundleID, privacy: .public)' isVisible=\(!app.isHidden) remaining=\(attemptsRemaining)")
        TilrLogger.shared.log("\(tag) retry: '\(bundleID)' isVisible=\(!app.isHidden) remaining=\(attemptsRemaining)", category: "windows")

        if !app.isHidden != desiredVisible {
            if !desiredVisible {
                Logger.windows.info("[hide] osascript fallback: firing osascript (state drifted from AppKit)")
                TilrLogger.shared.log("[hide] osascript fallback: firing osascript (state drifted from AppKit)", category: "windows")
                setHiddenViaOsascript(bundleID: bundleID, hidden: true)
            } else {
                app.unhide()
            }
        }
        scheduleHiddenStateRetry(bundleID: bundleID, desiredVisible: desiredVisible, attemptsRemaining: attemptsRemaining - 1)
    }
}

private func readWindowSize(bundleID: String) -> CGSize? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let axWindow = contentWindow(forApp: axApp, bundleID: bundleID) else { return nil }
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &ref) == .success, let ref else { return nil }
    var size = CGSize.zero
    AXValueGetValue(ref as! AXValue, .cgSize, &size)
    return size
}

@MainActor
func retryUntilWindowMatches(
    bundleID: String,
    targetSize: CGSize,
    tolerance: CGFloat = 2.0,
    firstCheckAfter: TimeInterval = 0.01,
    maxAttempts: Int = 8,
    reapply: @escaping () -> Void
) {
    func matches(_ size: CGSize?) -> Bool {
        guard let size else { return false }
        return abs(size.width - targetSize.width) <= tolerance &&
               abs(size.height - targetSize.height) <= tolerance
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + firstCheckAfter) {
        let initial = readWindowSize(bundleID: bundleID)
        if matches(initial) {
            let w = initial!.width
            Logger.layout.info("verify: '\(bundleID, privacy: .public)' matches on attempt 0 (w=\(w, privacy: .public))")
            return
        }

        func attempt(_ n: Int) {
            guard n <= maxAttempts else {
                let got = readWindowSize(bundleID: bundleID)
                let ws = got.map { "\($0.width)" } ?? "?"
                Logger.layout.info("verify: '\(bundleID, privacy: .public)' gave up after \(n - 1, privacy: .public) attempts (want w=\(targetSize.width, privacy: .public), got w=\(ws, privacy: .public))")
                return
            }
            let retryDelays: [TimeInterval] = [0.02, 0.05, 0.1, 0.2, 0.2, 0.2, 0.2]
            let delay = n <= retryDelays.count ? retryDelays[n - 1] : retryDelays.last!
            reapply()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let current = readWindowSize(bundleID: bundleID)
                if matches(current) {
                    let w = current!.width
                    Logger.layout.info("verify: '\(bundleID, privacy: .public)' matches on attempt \(n, privacy: .public) (w=\(w, privacy: .public))")
                    return
                }
                attempt(n + 1)
            }
        }

        attempt(1)
    }
}

/// Fallback hide mechanism using osascript / System Events. Called only when
/// AppKit `app.hide()` has been tried first and the hidden state has since
/// drifted back to visible. Fire-and-forget; errors are swallowed silently.
private func setHiddenViaOsascript(bundleID: String, hidden: Bool) {
    let appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
    Logger.windows.info("[hide] osascript: '\(bundleID, privacy: .public)' appName=\(appName ?? "nil", privacy: .public)")
    TilrLogger.shared.log("[hide] osascript: '\(bundleID)' appName=\(appName ?? "nil")", category: "windows")
    guard let name = appName else { return }
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
