import Foundation
import Observation

/// Capture lifecycle + state machine the UI binds to directly.
/// idle → requestingPermission → recording → stopping → idle, with
/// failed(message) reachable from any state.
@MainActor
@Observable
final class RecorderService {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case stopping
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastRecordingURL: URL?

    /// Set when a recording just finished, to drive the "generate a runbook?"
    /// prompt. Cleared once the user answers.
    private(set) var justFinishedURL: URL?
    /// Fired on the main actor when a recording finishes (e.g. to reveal the bar).
    var onRecordingFinished: ((URL) -> Void)?

    func clearJustFinished() { justFinishedURL = nil }

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .requestingPermission || state == .stopping }

    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    private let store = RecordingStore()
    private var engine: CaptureEngine?
    private var timerTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pendingURL: URL?

    func toggle() {
        switch state {
        case .recording: stop()
        case .idle, .failed: start()
        case .requestingPermission, .stopping: break
        }
    }

    func start() {
        guard state == .idle || failureMessage != nil else { return }
        state = .requestingPermission

        Task {
            // Mic is best-effort: if denied we still capture screen + system audio.
            _ = await Permissions.requestMicrophone()

            // Trigger the Screen Recording TCC prompt on first use (a no-op if
            // already granted). We deliberately do NOT hard-gate on
            // CGPreflightScreenCaptureAccess(): it returns false spuriously —
            // notably with ad-hoc signing and until the app is relaunched after a
            // grant — which sends you to Settings even though capture would work.
            // The real source of truth is whether the capture actually starts.
            Permissions.requestScreenRecording()

            let started = Date()
            let url = store.newRecordingURL(startedAt: started)
            let engine = CaptureEngine()
            do {
                try await engine.start(url: url)
            } catch {
                // Only now — capture genuinely failed — consider it a permission
                // problem and guide to Settings.
                if Permissions.hasScreenRecording() {
                    state = .failed(error.localizedDescription)   // some other failure
                } else {
                    Permissions.openScreenRecordingSettings()
                    state = .failed("Grant Screen Recording in System Settings ▸ Privacy & Security, then quit and reopen ai-runbooks.")
                }
                return
            }

            self.engine = engine
            self.startedAt = started
            self.pendingURL = url
            self.elapsed = 0
            state = .recording
            startTimer()
        }
    }

    func stop() {
        guard state == .recording else { return }
        state = .stopping
        stopTimer()

        let engine = self.engine
        let url = self.pendingURL
        let started = self.startedAt
        let duration = self.elapsed

        Task {
            let ok = await engine?.stop() ?? false
            if ok, let url, let started {
                store.writeSidecar(for: url, startedAt: started, duration: duration, display: "main")
                lastRecordingURL = url
                justFinishedURL = url
                onRecordingFinished?(url)
            }
            self.engine = nil
            self.pendingURL = nil
            self.startedAt = nil
            self.elapsed = 0
            state = ok ? .idle : .failed("Recording could not be finalized.")
        }
    }

    private func startTimer() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let started = self.startedAt else { break }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
