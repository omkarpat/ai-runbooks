import AppKit
import Observation

/// Menu-bar icon with Claude-app-style gestures:
///   • left-click       → toggle the floating command bar (show / hide)
///   • long-press       → open the options menu
///   • right-click      → open the options menu (conventional shortcut)
/// The icon reflects recording state.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let recorder: RecorderService
    private let onToggleBar: () -> Void
    private let longPressSeconds: TimeInterval = 0.35

    init(recorder: RecorderService, onToggleBar: @escaping () -> Void) {
        self.recorder = recorder
        self.onToggleBar = onToggleBar
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "ai-runbooks — click to toggle, long-press for options"
        }
        updateIcon()
        observeRecordingState()
    }

    // MARK: Gestures

    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent

        if event?.type == .rightMouseDown {
            showMenu()
            return
        }

        // Left-click: distinguish a tap (toggle) from a hold (menu). Wait up to
        // longPressSeconds for the mouse-up; if it doesn't come, it's a long-press.
        let deadline = Date(timeIntervalSinceNow: longPressSeconds)
        let mouseUp = NSApp.nextEvent(matching: [.leftMouseUp],
                                      until: deadline,
                                      inMode: .eventTracking,
                                      dequeue: true)
        if mouseUp == nil {
            showMenu()          // still held past the threshold → long-press
        } else {
            onToggleBar()       // released quickly → tap
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        let bar = NSMenuItem(title: "Toggle Command Bar", action: #selector(menuToggleBar), keyEquivalent: "")
        bar.target = self
        menu.addItem(bar)

        let rec = NSMenuItem(title: recorder.isRecording ? "Stop Recording" : "Start Recording",
                             action: #selector(menuToggleRecording), keyEquivalent: "")
        rec.target = self
        menu.addItem(rec)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ai-runbooks", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.maxY + 4),
                   in: button)
    }

    @objc private func menuToggleBar() { onToggleBar() }
    @objc private func menuToggleRecording() { recorder.toggle() }
    @objc private func menuQuit() { NSApplication.shared.terminate(nil) }

    // MARK: Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name = recorder.isRecording ? "record.circle.fill" : "record.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "ai-runbooks")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = recorder.isRecording ? .systemRed : nil
    }

    /// Re-render the icon whenever recording state changes (Observation fires
    /// onChange once, so we re-arm each time).
    private func observeRecordingState() {
        withObservationTracking {
            _ = recorder.isRecording
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observeRecordingState()
            }
        }
    }
}
