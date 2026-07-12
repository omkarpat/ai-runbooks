import SwiftUI

@main
struct RunbooksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu-bar icon is an AppKit NSStatusItem (see StatusItemController)
        // so we can control click vs. long-press gestures. This app has no
        // standard windows; the floating command bar is its own NSPanel.
        Settings { EmptyView() }
    }
}
