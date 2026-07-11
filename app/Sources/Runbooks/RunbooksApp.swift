import SwiftUI

@main
struct RunbooksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            Button("Show Command Bar") { model.showBar() }
                .keyboardShortcut("b")
            Button(model.recorder.isRecording ? "Stop Recording" : "Start Recording") {
                model.recorder.toggle()
            }
            Divider()
            Button("Quit ai-runbooks") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: model.recorder.isRecording ? "record.circle.fill" : "record.circle")
                .symbolRenderingMode(model.recorder.isRecording ? .multicolor : .monochrome)
        }
    }
}
