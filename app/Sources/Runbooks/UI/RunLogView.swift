import SwiftUI

/// Scrolling transcript of AgentEvents: assistant text, tool-call chips, and
/// status / error lines. Auto-scrolls to the newest item.
struct RunLogView: View {
    var agent: AgentRunService

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if agent.transcript.isEmpty {
                        Text("Send a prompt to start a run. The latest recording is attached automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    ForEach(agent.transcript) { item in
                        row(item).id(item.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: agent.transcript.count) {
                if let last = agent.transcript.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: AgentRunService.Item) -> some View {
        switch item.kind {
        case .user:
            bubble(item.text, tint: .accentColor.opacity(0.18), align: .trailing)
        case .assistant:
            bubble(item.text, tint: .gray.opacity(0.16), align: .leading)
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill").font(.caption2)
                Text(item.text).font(.caption.weight(.semibold))
                if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.blue.opacity(0.14)))
        case .status:
            Text(item.text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func bubble(_ text: String, tint: Color, align: HorizontalAlignment) -> some View {
        HStack {
            if align == .trailing { Spacer(minLength: 24) }
            Text(text)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint))
                .frame(maxWidth: 260, alignment: align == .trailing ? .trailing : .leading)
            if align == .leading { Spacer(minLength: 24) }
        }
        .frame(maxWidth: .infinity, alignment: align == .trailing ? .trailing : .leading)
    }
}
