// Lifecycle is toggle, not auto-dismiss like PopupWindow.
import AppKit
import SwiftUI

final class StatusOverlayWindow {

    private var panel: NSPanel?

    func toggle(content: String, on screen: NSScreen) {
        if let existing = panel {
            hide(existing)
        } else {
            show(content: content, on: screen)
        }
    }

    func hide() {
        guard let existing = panel else { return }
        hide(existing)
    }

    private func show(content: String, on screen: NSScreen) {
        let p = makePanel(content: content, screen: screen)
        panel = p

        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 1
        }
    }

    private func hide(_ p: NSPanel) {
        panel = nil

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            p.close()
        }
    }

    private func makePanel(content: String, screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating

        let view = StatusOverlayView(content: content)
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        hosting.layout()
        let size = hosting.fittingSize

        panel.setContentSize(size)

        let sf = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(
            x: sf.midX - size.width / 2,
            y: sf.midY - size.height / 2
        ))

        return panel
    }
}

private struct StatusOverlayView: View {
    let content: String

    var body: some View {
        Text(content)
            .font(.custom("Menlo", size: 30))
            .foregroundColor(Color(hex: "#00ff88").opacity(0.95))
            .multilineTextAlignment(.leading)
            .lineSpacing(4)
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
