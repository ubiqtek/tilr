import AppKit
import OSLog
import SwiftUI

final class PopupWindow {

    private var panel: NSPanel?
    private var hideTimer: Timer?

    func show(_ message: String, duration: TimeInterval = 1.2) {
        Logger.popup.info("show space: \(message, privacy: .public)")
        hideTimer?.invalidate()
        panel?.close()

        let panel = makePanel(message: message)
        self.panel = panel

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 1
        }

        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.close()
            self?.panel = nil
        })
    }

    private func makePanel(message: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating

        let view = PopupView(message: message)
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        // Force layout so we can read the real size
        hosting.layout()
        let size = hosting.fittingSize

        panel.setContentSize(size)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(
            x: sf.midX - size.width / 2,
            y: sf.midY - size.height / 2
        ))

        return panel
    }
}

private struct PopupView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.custom("Menlo", size: 30))
            .foregroundColor(Color(hex: "#00ff88").opacity(0.95))
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: "#1a1a2e").opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "#4a4a6a").opacity(0.8), lineWidth: 1.5)
                    )
            )
            .fixedSize()
    }
}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
