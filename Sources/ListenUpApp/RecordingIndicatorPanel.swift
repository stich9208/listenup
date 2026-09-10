import AppKit
import SwiftUI

@MainActor
final class RecordingIndicatorController {
    private var panel: NSPanel?

    func show() {
        if let panel {
            position(panel)
            panel.orderFrontRegardless()
            return
        }

        let size = NSSize(width: 106, height: 38)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: RecordingIndicatorView())
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .utilityWindow

        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.maxX - panel.frame.width - 18,
                y: visibleFrame.maxY - panel.frame.height - 18
            )
        )
    }
}

private struct RecordingIndicatorView: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)

            Text("녹음 중")
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        }
    }
}
