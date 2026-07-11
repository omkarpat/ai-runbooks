import Foundation

/// Opaque identifier for a single agent run.
struct RunID: Hashable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
}

/// Connection state of the underlying runtime, surfaced as a status dot in the UI.
enum RuntimeStatus: Sendable {
    case disconnected
    case connecting
    case ready
}

/// Events streamed back from a run, from start to a terminal state.
enum AgentEvent: Sendable {
    case runStarted(RunID)
    case assistantText(String)            // streamed tokens / messages
    case toolCall(name: String, detail: String)
    case runCompleted(RunID)
    case runFailed(RunID, String)         // String rather than Error to stay Sendable-friendly
}

/// Context handed to a run — the latest recording and the workspace it operates on.
struct RunContext: Sendable {
    var latestRecordingURL: URL?
    var workspacePath: String?
}

/// The one contract everything downstream hides behind (MockRuntime today,
/// a NemoClaw/OpenShell gateway or HoloDesktop bridge tomorrow). Swapping the
/// implementation should touch only the file that conforms to this protocol.
protocol AgentRuntime {
    /// Start a run from a chat prompt. Streams events until a terminal state.
    func startRun(prompt: String, context: RunContext) -> AsyncThrowingStream<AgentEvent, Error>
    func cancelRun(id: RunID) async throws
    var status: RuntimeStatus { get }
}
