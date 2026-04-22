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

    guard let axWindow = contentWindow(forApp: axApp, bundleID: bundleID) else {
        Logger.layout.info("AX: no content window for '\(bundleID, privacy: .public)' — skipping")
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

    return posResult == .success && sizeResult1 == .success
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
            app.hide()
        } else {
            app.unhide()
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

        let current = app.isHidden
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
    firstCheckAfter: TimeInterval = 0.3,
    retryInterval: TimeInterval = 0.2,
    maxAttempts: Int = 4,
    reapply: @escaping () -> Void
) {
    func matches(_ size: CGSize?) -> Bool {
        guard let size else { return false }
        return abs(size.width - targetSize.width) <= tolerance
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
            reapply()
            DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
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
