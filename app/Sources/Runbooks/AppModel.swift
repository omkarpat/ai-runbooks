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
    // Chat bar is wired to the real NemoClaw Hermes agent (skills + sandbox
    // tools) via its OpenAI-compatible API on localhost:8642. Swap to
    // OpenAIRuntime() for direct OpenAI, or MockRuntime() for an offline demo.
    let agent = AgentRunService(runtime: HermesRuntime())

    @ObservationIgnored var barController: FloatingBarController?

    private init() {}

    func showBar() { barController?.show() }
    func toggleBar() { barController?.toggle() }
}
