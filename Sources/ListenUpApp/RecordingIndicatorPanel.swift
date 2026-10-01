import AppKit
import SwiftUI

@MainActor
final class RecordingIndicatorController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let defaults: UserDefaults
    private let positionKey = "ListenUpRecordingIndicatorOrigin"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func show(isPaused: Bool = false) {
        if let panel {
            (panel.contentView as? RecordingIndicatorHostingView)?.rootView = RecordingIndicatorView(isPaused: isPaused)
            position(panel)
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 58, height: 58)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = RecordingIndicatorHostingView(rootView: RecordingIndicatorView(isPaused: isPaused))
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.animationBehavior = .utilityWindow

        position(panel)
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() { panel?.orderOut(nil) }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        defaults.set(NSStringFromPoint(panel.frame.origin), forKey: positionKey)
    }

    private func position(_ panel: NSPanel) {
        let saved = defaults.string(forKey: positionKey).map(NSPointFromString)
        let screen = saved.flatMap { origin in
            NSScreen.screens.first { $0.visibleFrame.intersects(NSRect(origin: origin, size: panel.frame.size)) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = saved ?? NSPoint(x: visible.maxX - panel.frame.width - 18, y: visible.maxY - panel.frame.height - 18)
        panel.setFrameOrigin(Self.clampedOrigin(origin, panelSize: panel.frame.size, visibleFrame: visible))
    }

    /// Keep a saved widget reachable after a monitor is removed or resized.
    static func clampedOrigin(_ origin: NSPoint, panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)),
            y: min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelSize.height))
        )
    }
}

/// Remember the pointer gesture independently of the window position. Moving
/// away and back is still a drag, and a press alone never activates the app.
struct RecordingIndicatorPointerGesture {
    private var pressPoint: NSPoint?
    private var initialOrigin: NSPoint = .zero
    private(set) var hasDragged = false
    private let dragThreshold: CGFloat = 4

    mutating func begin(at point: NSPoint, windowOrigin: NSPoint) {
        pressPoint = point
        initialOrigin = windowOrigin
        hasDragged = false
    }

    mutating func drag(to point: NSPoint) -> NSPoint? {
        guard let pressPoint else { return nil }
        let dx = point.x - pressPoint.x
        let dy = point.y - pressPoint.y
        if hypot(dx, dy) >= dragThreshold { hasDragged = true }
        guard hasDragged else { return nil }
        return NSPoint(x: initialOrigin.x + dx, y: initialOrigin.y + dy)
    }

    mutating func finish(at point: NSPoint) -> Bool {
        guard let pressPoint else { return false }
        let isClick = !hasDragged && hypot(point.x - pressPoint.x, point.y - pressPoint.y) < dragThreshold
        self.pressPoint = nil
        hasDragged = false
        return isClick
    }
}

private final class RecordingIndicatorHostingView: NSHostingView<RecordingIndicatorView> {
    private var pointerGesture = RecordingIndicatorPointerGesture()

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Keep SwiftUI child views from intercepting the native pointer sequence.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        pointerGesture.begin(at: window.convertPoint(toScreen: event.locationInWindow), windowOrigin: window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let origin = pointerGesture.drag(to: window.convertPoint(toScreen: event.locationInWindow)) else { return }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        if pointerGesture.finish(at: window.convertPoint(toScreen: event.locationInWindow)) {
            let mainWindow = NSApplication.shared.windows.first { !($0 is NSPanel) }
            if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

private struct RecordingIndicatorView: View {
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var indicatorColor: Color { isPaused ? .orange : .red }
    private var status: String { isPaused ? "ListenUp 녹음 일시정지" : "ListenUp 녹음 중" }

    var body: some View {
        ZStack {
            Circle()
                .stroke(indicatorColor.opacity(!isPaused && pulse ? 0.08 : 0.55), lineWidth: 3)
                .scaleEffect(!isPaused && pulse ? 1.08 : 0.78)
            Circle()
                .fill(.ultraThickMaterial)
                .padding(5)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
            Circle()
                .fill(indicatorColor)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .offset(x: 17, y: 17)
        }
        .frame(width: 58, height: 58)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) { pulse = true }
        }
        .help("\(status) · 드래그하여 이동")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status)
        .accessibilityHint("드래그하여 위치를 바꾸거나 클릭하여 ListenUp으로 돌아갑니다")
    }
}
