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

            if !Permissions.hasScreenRecording() {
                Permissions.requestScreenRecording()
                if !Permissions.hasScreenRecording() {
                    Permissions.openScreenRecordingSettings()
                    state = .failed("Enable Screen Recording in System Settings ▸ Privacy & Security, then try again.")
                    return
                }
            }

            let started = Date()
            let url = store.newRecordingURL(startedAt: started)
            let engine = CaptureEngine()
            do {
                try await engine.start(url: url)
            } catch {
                state = .failed(error.localizedDescription)
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
