import AppKit

/// Creates the floating command bar once the app finishes launching. The bar
/// lives outside SwiftUI's scene graph so it can be a borderless, always-on-top
/// panel anchored to the top of the screen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        let controller = FloatingBarController(recorder: model.recorder, agent: model.agent)
        model.barController = controller

        // Menu-bar icon: left-click toggles the bar, long-press/right-click opens
        // the options menu.
        statusItem = StatusItemController(recorder: model.recorder) { [weak controller] in
            controller?.toggle()
        }

        // Reveal the bar when a recording finishes so the "generate a runbook?"
        // prompt is visible even if the bar was hidden.
        model.recorder.onRecordingFinished = { [weak controller] _ in controller?.show() }

        // Start hidden (Claude-app style) — click the menu-bar icon to reveal it.
    }
}
