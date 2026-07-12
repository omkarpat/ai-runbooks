import Foundation

/// Turns a recording into a runbook by running `scripts/generate-runbook.sh`
/// out-of-process (it drives the provisioned NemoClaw sandbox). The pipeline's
/// stderr streams as `.progress`; the finished runbook markdown (the script's
/// stdout) arrives as `.runbook`.
enum PipelineEvent {
    case progress(String)
    case runbook(String)
    case failed(String)
}

struct PipelineRunner {
    /// Locate scripts/generate-runbook.sh by walking up from the cwd and the app
    /// bundle (works for `make run` from app/ and for a bundle inside the repo).
    static func scriptURL() -> URL? {
        let fm = FileManager.default
        let starts = [URL(fileURLWithPath: fm.currentDirectoryPath), Bundle.main.bundleURL]
        for start in starts {
            var dir = start
            for _ in 0..<7 {
                let candidate = dir.appendingPathComponent("scripts/generate-runbook.sh")
                if fm.fileExists(atPath: candidate.path) { return candidate }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
        }
        return nil
    }

    func run(recordingURL: URL, workflow: String) -> AsyncStream<PipelineEvent> {
        AsyncStream { continuation in
            guard let script = Self.scriptURL() else {
                continuation.yield(.failed("Couldn't find scripts/generate-runbook.sh — provision the sandbox first (scripts/provision-sandbox.sh)."))
                continuation.finish()
                return
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script.path, recordingURL.path, workflow]
            let home = NSHomeDirectory()
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home
            env["PATH"] = "\(home)/.local/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            proc.environment = env

            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            // Stream the pipeline's stderr line-by-line as progress.
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { continuation.yield(.progress(trimmed)) }
                }
            }

            proc.terminationHandler = { p in
                errPipe.fileHandleForReading.readabilityHandler = nil
                // The runbook markdown is small — read it all at exit.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let runbook = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if p.terminationStatus == 0 && !runbook.isEmpty {
                    continuation.yield(.runbook(runbook))
                } else if p.terminationStatus == 0 {
                    continuation.yield(.failed("Pipeline finished but produced no runbook."))
                } else {
                    continuation.yield(.failed("Pipeline exited with status \(p.terminationStatus)."))
                }
                continuation.finish()
            }

            do {
                try proc.run()
            } catch {
                continuation.yield(.failed(error.localizedDescription))
                continuation.finish()
                return
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason, proc.isRunning { proc.terminate() }
            }
        }
    }
}
