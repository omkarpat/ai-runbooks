import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus (so the chat field works) and
/// dismisses on Escape, without stealing the whole app's activation.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

/// Hosts `FloatingBarView` in an always-on-top panel anchored to the top-center
/// of the main screen. The panel auto-sizes to its SwiftUI content; when the run
/// log expands, we re-anchor so the top edge stays put and it grows downward.
@MainActor
final class FloatingBarController {
    private let panel: FloatingPanel
    private let hosting: NSHostingView<FloatingBarView>

    private var topAnchor: CGFloat = 0
    private var didAnchor = false
    private var repositioning = false

    init(recorder: RecorderService, agent: AgentRunService) {
        hosting = NSHostingView(rootView: FloatingBarView(recorder: recorder, agent: agent))
        hosting.sizingOptions = [.preferredContentSize]

        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 616, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true                  // native shadow follows the clipped pill
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidResize),
            name: NSWindow.didResizeNotification, object: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(userDidMove),
            name: NSWindow.didMoveNotification, object: panel)
    }

    func show() {
        if !didAnchor { computeInitialPosition(); didAnchor = true }
        reanchor()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel.orderOut(nil) }

    func toggle() { panel.isVisible ? hide() : show() }

    private func computeInitialPosition() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        topAnchor = vf.maxY - 12
        let x = vf.midX - panel.frame.width / 2
        panel.setFrameOrigin(NSPoint(x: x, y: topAnchor - panel.frame.height))
    }

    /// Keep the panel's top edge at `topAnchor`, letting height grow downward.
    private func reanchor() {
        repositioning = true
        var frame = panel.frame
        frame.origin.y = topAnchor - frame.height
        panel.setFrame(frame, display: true)
        repositioning = false
    }

    @objc private func contentDidResize() {
        guard !repositioning else { return }
        reanchor()
    }

    @objc private func userDidMove() {
        guard !repositioning else { return }
        topAnchor = panel.frame.maxY      // user dragged the bar; remember the new top
    }
}
