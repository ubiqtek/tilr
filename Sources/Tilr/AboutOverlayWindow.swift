import AppKit
import SwiftUI

final class AboutOverlayWindow {

    private var panel: NSPanel?

    func show(on screen: NSScreen) {
        guard panel == nil else { return }
        let p = makePanel(screen: screen)
        panel = p

        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            p.close()
        }
    }

    private func makePanel(screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating

        let view = AboutOverlayView {
            self.hide()
        }
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

private struct AboutOverlayView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tilr")
                .font(.custom("Menlo", size: 30))
                .foregroundColor(Color(hex: "#00ff88").opacity(0.95))
            Text(Version.full)
                .font(.custom("Menlo", size: 20))
                .foregroundColor(Color(hex: "#00ff88").opacity(0.85))
            Text("built \(Version.buildDate) · io.ubiqtek.tilr")
                .font(.custom("Menlo", size: 13))
                .foregroundColor(Color(hex: "#00ff88").opacity(0.60))
        }
        .multilineTextAlignment(.leading)
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
        .onTapGesture { dismiss() }
        .keyboardShortcut(.escape, modifiers: [])
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
