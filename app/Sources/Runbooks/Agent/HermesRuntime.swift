import Foundation

/// Real `AgentRuntime` backed by the NemoClaw **Hermes agent** — the full agent
/// (skills + sandbox tools), not just raw model inference. Talks to the agent's
/// OpenAI-compatible API exposed by the OpenShell gateway on localhost.
///
/// Config from the environment / repo-root `.env`:
///   HERMES_API_URL    default http://127.0.0.1:8642/v1/chat/completions
///   HERMES_API_TOKEN  bearer token — `nemohermes runbooks gateway-token --quiet`
///
/// The agent is non-streaming (it reasons + calls tools, then returns a final
/// message), so this surfaces a "working" tool chip and yields the full reply.
final class HermesRuntime: AgentRuntime {
    private let endpoint: URL
    private let token: String?
    private let model = "hermes-agent"

    var status: RuntimeStatus { token == nil ? .disconnected : .ready }

    init() {
        let urlString = SecretsLoader.value(for: "HERMES_API_URL")
            ?? "http://127.0.0.1:8642/v1/chat/completions"
        self.endpoint = URL(string: urlString) ?? URL(string: "http://127.0.0.1:8642/v1/chat/completions")!
        self.token = SecretsLoader.value(for: "HERMES_API_TOKEN")
    }

    func startRun(prompt: String, context: RunContext) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let id = RunID()
                continuation.yield(.runStarted(id))

                guard let token else {
                    continuation.yield(.runFailed(id, "HERMES_API_TOKEN not found. Run `nemohermes runbooks gateway-token --quiet` and add it to .env, then relaunch."))
                    continuation.finish()
                    return
                }

                continuation.yield(.toolCall(name: "hermes-agent", detail: "thinking + running tools…"))

                do {
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 300     // the agent can run tools for a while
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "messages": [
                            ["role": "user", "content": Self.userMessage(prompt, context: context)],
                        ],
                    ])

                    let (data, response) = try await URLSession.shared.data(for: req)
                    if Task.isCancelled {
                        continuation.yield(.runFailed(id, "Run cancelled."))
                        continuation.finish()
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.yield(.runFailed(id, "No HTTP response from the Hermes agent."))
                        continuation.finish()
                        return
                    }
                    guard http.statusCode == 200 else {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        continuation.yield(.runFailed(id, "Hermes HTTP \(http.statusCode): \(Self.snippet(body)). Is the gateway port forwarded (openshell forward start --background 8642 runbooks)?"))
                        continuation.finish()
                        return
                    }

                    let content = Self.extractContent(data)
                    continuation.yield(.assistantText(content.isEmpty ? "(no content returned)" : content))
                    continuation.yield(.runCompleted(id))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.runFailed(id, "Run cancelled."))
                    continuation.finish()
                } catch {
                    continuation.yield(.runFailed(id, "\(error.localizedDescription). Is the Hermes gateway running and port 8642 forwarded?"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelRun(id: RunID) async throws {
        // Cancellation is driven by the stream's onTermination handler.
    }

    private static func userMessage(_ prompt: String, context: RunContext) -> String {
        var message = prompt
        // Live KB grounding: prepend the current catalog so runbook queries
        // don't depend on the agent model driving tool calls (weak local
        // models can't). Best-effort — chat proceeds ungrounded on failure.
        if let catalog = kbContext() {
            message = "[Context — \(catalog)]\n\n" + message
        }
        if let recording = context.latestRecordingURL {
            message += "\n\n[Latest screen recording available at: \(recording.path)]"
        }
        return message
    }

    /// Run scripts/kb-context.sh (located like PipelineRunner's script) for a
    /// compact catalog summary. Returns nil on any failure or empty output.
    private static func kbContext() -> String? {
        let fm = FileManager.default
        var script: URL?
        for start in [URL(fileURLWithPath: fm.currentDirectoryPath), Bundle.main.bundleURL] {
            var dir = start
            for _ in 0..<7 {
                let candidate = dir.appendingPathComponent("scripts/kb-context.sh")
                if fm.fileExists(atPath: candidate.path) { script = candidate; break }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
            if script != nil { break }
        }
        guard let script else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }

        // Bounded wait — grounding must never stall the chat send.
        let deadline = Date().addingTimeInterval(10)
        while proc.isRunning && Date() < deadline { usleep(100_000) }
        if proc.isRunning { proc.terminate(); return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else { return nil }
        return text
    }

    private static func extractContent(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return ""
        }
        return (message["content"] as? String) ?? ""
    }

    private static func snippet(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 200 ? String(t.prefix(200)) + "…" : t
    }
}
