import AppKit
import OSLog

// C-compatible AX observer callback. Bridges to SidebarResizeObserver via refcon.
private func observerCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let obs = Unmanaged<SidebarResizeObserver>.fromOpaque(refcon).takeUnretainedValue()
    // AX callbacks are dispatched on the main run loop (we registered via CFRunLoopGetMain).
    MainActor.assumeIsolated {
        obs.handleResize(of: element)
    }
}

@MainActor
final class SidebarResizeObserver {

    // Session-only ratio overrides keyed by space name. Not persisted.
    private var ratioOverride: [String: Double] = [:]

    // Currently observed space context.
    private var activeSpaceName: String?
    private var mainBundleID: String?
    private var mainWindowElement: AXUIElement?
    private var sidebarWindowElements: [(bundleID: String, element: AXUIElement)] = []
    private var activeScreen: NSScreen?
    private var axObservers: [AXObserver] = []

    // Intended frames set before startObserving so snap-back detection doesn't
    // rely on async AX reads (which may lag behind the actual move).
    private var storedMainFrame: CGRect?
    private var storedSidebarFrame: CGRect?

    // Per-bundleID suppression deadlines. Entries expire naturally; no cleanup timer needed.
    private var suppressedUntil: [String: Date] = [:]

    // MARK: - Public API

    func ratio(for spaceName: String) -> Double? {
        ratioOverride[spaceName]
    }

    func setExpectedFrames(mainFrame: CGRect, sidebarFrame: CGRect) {
        Logger.layout.info("setExpectedFrames: main x=\(mainFrame.origin.x) w=\(mainFrame.width), sidebar x=\(sidebarFrame.origin.x) w=\(sidebarFrame.width)")
        storedMainFrame = mainFrame
        storedSidebarFrame = sidebarFrame
    }

    func startObserving(
        space: SpaceDefinition,
        name: String,
        screen: NSScreen,
        mainBundleID: String?,
        sidebarBundleIDs: [String]
    ) {
        tearDown()

        activeSpaceName = name
        self.mainBundleID = mainBundleID
        activeScreen = screen

        if let mainID = mainBundleID {
            if let (observer, element) = makeObserver(bundleID: mainID) {
                axObservers.append(observer)
                mainWindowElement = element
            }
        }

        var sidebars: [(bundleID: String, element: AXUIElement)] = []
        for bundleID in sidebarBundleIDs {
            if let (observer, element) = makeObserver(bundleID: bundleID) {
                axObservers.append(observer)
                sidebars.append((bundleID: bundleID, element: element))
            }
        }
        sidebarWindowElements = sidebars
    }

    func stopObserving() {
        tearDown()
    }

    /// Sets the frame of the window for `bundleID` and marks that bundleID as
    /// suppressed for 600 ms to swallow the echo AX resize notification.
    func setFrameAndSuppress(bundleID: String, frame: CGRect) {
        suppressedUntil[bundleID] = Date().addingTimeInterval(0.6)
        setWindowFrame(bundleID: bundleID, frame: frame)
    }

    // MARK: - Callback (called from C shim)

    func handleResize(of element: AXUIElement) {
        // Identify which tracked bundleID fired.
        let bundleID: String
        if let mainEl = mainWindowElement, CFEqual(mainEl, element) {
            bundleID = mainBundleID ?? ""
        } else if let match = sidebarWindowElements.first(where: { CFEqual($0.element, element) }) {
            bundleID = match.bundleID
        } else {
            Logger.layout.info("resize callback: element matched neither main nor any sidebar — ignoring element=\(String(describing: element), privacy: .public)")
            return
        }

        // Suppress echo events from windows we just repositioned programmatically.
        if let deadline = suppressedUntil[bundleID] {
            if deadline > Date() { return }
            suppressedUntil.removeValue(forKey: bundleID)
        }

        guard let spaceName = activeSpaceName, let screen = activeScreen else { return }

        guard let frame = axFrame(of: element) else {
            Logger.layout.info("resize observer: could not read frame of changed element")
            return
        }

        let sf = screen.frame

        let isMain = mainWindowElement.map { CFEqual($0, element) } ?? false

        if isMain {
            let newRatio = (frame.width / sf.width).clamped(to: 0.1...0.9)
            ratioOverride[spaceName] = newRatio

            let sidebarFrame = CGRect(
                x: sf.minX + sf.width * newRatio,
                y: sf.minY,
                width: sf.width * (1 - newRatio),
                height: sf.height
            )
            for (sid, _) in sidebarWindowElements {
                setFrameAndSuppress(bundleID: sid, frame: sidebarFrame)
            }
            return
        }

        if let idx = sidebarWindowElements.firstIndex(where: { CFEqual($0.element, element) }) {
            let draggedBundleID = sidebarWindowElements[idx].bundleID

            // Snap-back detection: if the sidebar window has landed significantly to the
            // left of where it should be, the OS snapped it back to its pre-move position
            // rather than honouring our setFrameAndSuppress placement.
            // Use stored intended frames (set before the AX move) rather than reading AX
            // positions live, which may lag behind the async move.
            // Return early — do NOT update ratioOverride.
            if let mFrame = storedMainFrame, let sFrame = storedSidebarFrame {
                Logger.layout.info("resize observer: sidebar '\(draggedBundleID, privacy: .public)' x=\(frame.origin.x), main.maxX=\(mFrame.maxX), threshold=\(mFrame.maxX - sf.width * 0.15)")
                if frame.origin.x < mFrame.maxX - sf.width * 0.15 {
                    Logger.layout.info("resize observer: snap-back detected for sidebar '\(draggedBundleID, privacy: .public)' — reapplying frames")
                    if let mainID = mainBundleID {
                        setFrameAndSuppress(bundleID: mainID, frame: mFrame)
                    }
                    for (sid, _) in sidebarWindowElements {
                        setFrameAndSuppress(bundleID: sid, frame: sFrame)
                    }
                    return
                }
            } else {
                Logger.layout.info("resize observer: no stored frames available")
            }

            let newRatio = ((frame.origin.x - sf.origin.x) / sf.width).clamped(to: 0.1...0.9)
            ratioOverride[spaceName] = newRatio

            let mainFrame = CGRect(x: sf.minX, y: sf.minY, width: sf.width * newRatio, height: sf.height)
            let sidebarFrame = CGRect(
                x: sf.minX + sf.width * newRatio,
                y: sf.minY,
                width: sf.width * (1 - newRatio),
                height: sf.height
            )
            if let mainID = mainBundleID {
                setFrameAndSuppress(bundleID: mainID, frame: mainFrame)
            }
            for (sid, _) in sidebarWindowElements where sid != draggedBundleID {
                setFrameAndSuppress(bundleID: sid, frame: sidebarFrame)
            }
            return
        }
    }

    // MARK: - Private helpers

    private func makeObserver(bundleID: String) -> (AXObserver, AXUIElement)? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
        guard result == .success, let windowRef else {
            Logger.layout.info("resize observer: no main window for '\(bundleID, privacy: .public)' — skipping")
            return nil
        }
        let windowElement = windowRef as! AXUIElement

        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let createResult = AXObserverCreate(pid, observerCallback, &observer)
        guard createResult == .success, let observer else {
            Logger.layout.info("resize observer: AXObserverCreate failed for '\(bundleID, privacy: .public)' (err \(createResult.rawValue, privacy: .public))")
            return nil
        }

        let addResult = AXObserverAddNotification(observer, windowElement, kAXResizedNotification as CFString, refcon)
        guard addResult == .success else {
            Logger.layout.info("resize observer: AXObserverAddNotification failed for '\(bundleID, privacy: .public)' (err \(addResult.rawValue, privacy: .public))")
            return nil
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        return (observer, windowElement)
    }

    private func tearDown() {
        for observer in axObservers {
            // Remove the run loop source; AXObserverRemoveNotification is best-effort here
            // since we don't keep per-observer element refs after this point.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObservers.removeAll()
        mainWindowElement = nil
        sidebarWindowElements.removeAll()
        activeSpaceName = nil
        mainBundleID = nil
        activeScreen = nil
        storedMainFrame = nil
        storedSidebarFrame = nil
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }

        var point = CGPoint.zero
        var size  = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }

        return CGRect(origin: point, size: size)
    }
}

// MARK: - Comparable clamping

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
