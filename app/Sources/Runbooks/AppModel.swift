import Foundation
import Observation

/// Shared app state. Owns the services and a handle to the floating command
/// bar so both the SwiftUI `MenuBarExtra` and the AppKit `AppDelegate` can
/// reach them.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let recorder = RecorderService()
    let agent = AgentRunService(runtime: MockRuntime())

    @ObservationIgnored var barController: FloatingBarController?

    private init() {}

    func showBar() { barController?.show() }
    func toggleBar() { barController?.toggle() }
}
