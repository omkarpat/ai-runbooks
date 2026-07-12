import SwiftUI

/// The floating command bar: a rounded, translucent pill with a status dot,
/// compact record control, and a chat input. When a run has activity, the run
/// log expands above the input inside the same panel.
struct FloatingBarView: View {
    var recorder: RecorderService
    var agent: AgentRunService

    @State private var prompt: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !agent.transcript.isEmpty {
                RunLogView(agent: agent)
                    .frame(width: 600, height: 280)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                Divider()
            }

            if let message = recorder.failureMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(width: 600, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if let url = recorder.justFinishedURL, !agent.isRunning {
                runbookPrompt(url)
                Divider()
            }

            inputBar
        }
        .frame(width: 616)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 10)
        .padding(10)                       // breathing room for the shadow inside the clear window
        .onAppear { focused = true }
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            statusDot
            recordControl
            Divider().frame(height: 24)
            TextField("Ask the agent to build a runbook…", text: $prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .disabled(agent.isRunning)
                .onSubmit(send)
            trailingButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func runbookPrompt(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recording saved")
                    .font(.caption.weight(.semibold))
                Text("Generate a runbook for this?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not now") { recorder.clearJustFinished() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Generate") {
                agent.generateRunbook(recordingURL: url)
                recorder.clearJustFinished()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(width: 600)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
            .help(statusLabel)
    }

    private var recordControl: some View {
        HStack(spacing: 8) {
            Button(action: recorder.toggle) {
                ZStack {
                    Circle()
                        .fill(.red.opacity(recorder.isBusy ? 0.3 : 1))
                        .frame(width: 22, height: 22)
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 8, height: 8)
                    }
                    if recorder.isBusy { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(.plain)
            .disabled(recorder.isBusy)
            .help(recorder.isRecording ? "Stop recording" : "Start recording")

            if recorder.isRecording {
                Text(timeString(recorder.elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trailingButton: some View {
        Group {
            if agent.isRunning {
                Button(action: agent.cancel) {
                    Image(systemName: "stop.circle.fill")
                }
                .help("Cancel run")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Send")
            }
        }
        .buttonStyle(.plain)
        .font(.title2)
    }

    private var statusColor: Color {
        switch agent.runtimeStatus {
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .ready: return .green
        }
    }

    private var statusLabel: String {
        switch agent.runtimeStatus {
        case .disconnected: return "No Hermes token — check .env"
        case .connecting: return "Hermes connecting"
        case .ready: return "Hermes agent ready"
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func send() {
        guard !agent.isRunning else { return }
        let context = RunContext(
            latestRecordingURL: recorder.lastRecordingURL,
            workspacePath: FileManager.default.currentDirectoryPath
        )
        agent.start(prompt: prompt, context: context)
        prompt = ""
    }
}
