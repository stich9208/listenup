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

        let size = NSSize(width: 58, height: 58)
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
        panel.ignoresMouseEvents = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.red.opacity(pulse ? 0.08 : 0.55), lineWidth: 3)
                .scaleEffect(pulse ? 1.08 : 0.78)

            Circle()
                .fill(.ultraThickMaterial)
                .padding(5)

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)

            Circle()
                .fill(.red)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .offset(x: 17, y: 17)
        }
        .frame(width: 58, height: 58)
        .contentShape(Circle())
        .onTapGesture {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .help("ListenUp 녹음 중")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ListenUp 녹음 중")
        .accessibilityHint("클릭하면 ListenUp으로 돌아갑니다")
    }
}
