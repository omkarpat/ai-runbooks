import Foundation

/// v1 stub. Streams a canned run with realistic delays so the whole UI loop
/// (send → streaming transcript → tool chips → completion, plus cancel) is
/// exercisable with no backend. Replace this file to plug in a real runtime.
final class MockRuntime: AgentRuntime {
    var status: RuntimeStatus = .ready

    func startRun(prompt: String, context: RunContext) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let id = RunID()
                continuation.yield(.runStarted(id))

                let recording = context.latestRecordingURL?.lastPathComponent ?? "none"
                let steps: [AgentEvent] = [
                    .assistantText("Got it — working on: \u{201C}\(prompt)\u{201D}."),
                    .toolCall(name: "load_recording", detail: recording),
                    .assistantText("Inspecting the latest recording and the current workspace."),
                    .toolCall(name: "screen.analyze", detail: "detected 3 UI steps"),
                    .assistantText("Drafting a runbook from the captured steps…"),
                    .toolCall(name: "runbook.write", detail: "runbook-draft.md"),
                    .assistantText("Done. A draft runbook is ready for review."),
                ]

                for step in steps {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .milliseconds(650))
                    if Task.isCancelled { break }
                    continuation.yield(step)
                }

                if Task.isCancelled {
                    continuation.yield(.runFailed(id, "Run cancelled."))
                } else {
                    continuation.yield(.runCompleted(id))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelRun(id: RunID) async throws {
        // No-op for the mock; the stream's onTermination handles cancellation.
    }
}
