import AppKit

/// Creates the floating command bar once the app finishes launching. The bar
/// lives outside SwiftUI's scene graph so it can be a borderless, always-on-top
/// panel anchored to the top of the screen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        let controller = FloatingBarController(recorder: model.recorder, agent: model.agent)
        model.barController = controller
        controller.show()
    }
}
