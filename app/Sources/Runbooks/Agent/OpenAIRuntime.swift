import Foundation

/// Real `AgentRuntime` backed by OpenAI's streaming Chat Completions API, using
/// the key from the environment / repo-root `.env` (`OPENAI_API_KEY`). This is
/// the drop-in replacement for `MockRuntime` — swapping it in `AppModel` is the
/// only wiring change, per the v1 exit criteria.
///
/// Model is `OPENAI_MODEL` if set, else `gpt-4o-mini`.
final class OpenAIRuntime: AgentRuntime {
    private let apiKey: String?
    private let model: String
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    var status: RuntimeStatus { apiKey == nil ? .disconnected : .ready }

    init() {
        self.apiKey = SecretsLoader.value(for: "OPENAI_API_KEY")
        self.model = SecretsLoader.value(for: "OPENAI_MODEL") ?? "gpt-4o-mini"
    }

    func startRun(prompt: String, context: RunContext) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let id = RunID()
                continuation.yield(.runStarted(id))

                guard let apiKey else {
                    continuation.yield(.runFailed(id, "OPENAI_API_KEY not found. Add it to .env at the repo root (or export it) and relaunch."))
                    continuation.finish()
                    return
                }

                do {
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": Self.systemPrompt(context: context)],
                            ["role": "user", "content": prompt],
                        ],
                    ])

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.yield(.runFailed(id, "No HTTP response from OpenAI."))
                        continuation.finish()
                        return
                    }
                    guard http.statusCode == 200 else {
                        var detail = ""
                        for try await line in bytes.lines { detail += line }
                        continuation.yield(.runFailed(id, "OpenAI HTTP \(http.statusCode): \(Self.snippet(detail))"))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.toolCall(name: "openai.chat", detail: model))

                    var sawContent = false
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String, !content.isEmpty
                        else { continue }
                        sawContent = true
                        continuation.yield(.assistantText(content))
                    }

                    if Task.isCancelled {
                        continuation.yield(.runFailed(id, "Run cancelled."))
                    } else {
                        if !sawContent { continuation.yield(.assistantText("(no content returned)")) }
                        continuation.yield(.runCompleted(id))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.runFailed(id, "Run cancelled."))
                    continuation.finish()
                } catch {
                    continuation.yield(.runFailed(id, error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelRun(id: RunID) async throws {
        // Cancellation is driven by the stream's onTermination handler.
    }

    private static func systemPrompt(context: RunContext) -> String {
        var s = """
        You are the ai-runbooks assistant, a macOS menu-bar agent that helps turn \
        screen recordings into precise, replayable runbooks. Be concise and practical. \
        When asked to build a runbook, produce clear numbered steps (imperative action \
        + target + expected result), plus Preconditions and an Outcome.
        """
        if let recording = context.latestRecordingURL {
            s += "\n\nThe user's latest screen recording is at \(recording.path). "
                + "You cannot watch the video directly yet; if a task needs its contents, "
                + "say what you would extract and point the user at the recording pipeline."
        }
        return s
    }

    private static func snippet(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 300 ? String(t.prefix(300)) + "…" : t
    }
}
