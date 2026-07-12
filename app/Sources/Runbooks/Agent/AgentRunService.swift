import Foundation
import Observation

/// Owns run lifecycle and transcript state. Binds directly to the UI.
@MainActor
@Observable
final class AgentRunService {
    struct Item: Identifiable {
        enum Kind { case user, assistant, tool, status, error }
        let id = UUID()
        var kind: Kind
        var text: String
        var detail: String? = nil
    }

    private(set) var transcript: [Item] = []
    private(set) var isRunning = false

    let runtime: AgentRuntime
    var runtimeStatus: RuntimeStatus { runtime.status }

    private var runTask: Task<Void, Never>?
    private var currentRunID: RunID?

    init(runtime: AgentRuntime) {
        self.runtime = runtime
    }

    func start(prompt: String, context: RunContext) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        isRunning = true
        transcript.append(Item(kind: .user, text: trimmed))

        runTask = Task { [weak self] in
            guard let self else { return }
            let stream = self.runtime.startRun(prompt: trimmed, context: context)
            do {
                for try await event in stream {
                    self.apply(event)
                }
            } catch {
                self.transcript.append(Item(kind: .error, text: error.localizedDescription))
            }
            self.isRunning = false
            self.currentRunID = nil
        }
    }

    /// Run the recording→runbook pipeline (via scripts/generate-runbook.sh) and
    /// stream its progress + the finished runbook into the same run log.
    func generateRunbook(recordingURL: URL) {
        guard !isRunning else { return }
        isRunning = true
        transcript.append(Item(kind: .user, text: "Generate a runbook from \(recordingURL.lastPathComponent)"))
        transcript.append(Item(kind: .status, text: "Starting pipeline…"))

        let workflow = recordingURL.deletingPathExtension().lastPathComponent
        runTask = Task { [weak self] in
            for await event in PipelineRunner().run(recordingURL: recordingURL, workflow: workflow) {
                guard let self else { break }
                switch event {
                case .progress(let line):
                    self.transcript.append(Item(kind: .status, text: line))
                case .runbook(let markdown):
                    self.transcript.append(Item(kind: .assistant, text: markdown))
                    self.saveRunbook(markdown, for: recordingURL)
                case .failed(let message):
                    self.transcript.append(Item(kind: .error, text: message))
                }
            }
            self?.isRunning = false
        }
    }

    /// Persist the runbook next to its recording as `<name>.runbook.md`.
    private func saveRunbook(_ markdown: String, for recordingURL: URL) {
        let out = recordingURL.deletingPathExtension().appendingPathExtension("runbook.md")
        do {
            try markdown.write(to: out, atomically: true, encoding: .utf8)
            transcript.append(Item(kind: .status, text: "Saved \(out.lastPathComponent)"))
        } catch {
            transcript.append(Item(kind: .error, text: "Could not save runbook: \(error.localizedDescription)"))
        }
    }

    func cancel() {
        guard isRunning else { return }
        let id = currentRunID
        runTask?.cancel()
        if let id {
            Task { [runtime] in try? await runtime.cancelRun(id: id) }
        }
    }

    func clear() {
        guard !isRunning else { return }
        transcript.removeAll()
    }

    private func apply(_ event: AgentEvent) {
        switch event {
        case .runStarted(let id):
            currentRunID = id
            transcript.append(Item(kind: .status, text: "Run started"))
        case .assistantText(let text):
            // Coalesce streamed deltas into the current assistant bubble.
            if let last = transcript.last, last.kind == .assistant {
                transcript[transcript.count - 1].text += text
            } else {
                transcript.append(Item(kind: .assistant, text: text))
            }
        case .toolCall(let name, let detail):
            transcript.append(Item(kind: .tool, text: name, detail: detail))
        case .runCompleted:
            transcript.append(Item(kind: .status, text: "Run completed"))
        case .runFailed(_, let message):
            transcript.append(Item(kind: .error, text: message))
        }
    }
}
