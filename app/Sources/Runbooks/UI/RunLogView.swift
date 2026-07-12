import SwiftUI

/// Scrolling transcript. Assistant replies render as markdown; long runs of
/// status/progress lines (the pipeline logs) collapse into an expandable group.
struct RunLogView: View {
    var agent: AgentRunService

    /// Log groups (keyed by their first item's id) that the user has expanded.
    @State private var expandedLogs: Set<UUID> = []

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
                    ForEach(blocks) { block in
                        blockView(block).id(block.id)
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

    // MARK: Grouping

    /// A rendered unit: a normal item, or a collapsible run of status lines.
    private struct Block: Identifiable {
        let id: UUID
        enum Kind { case item(AgentRunService.Item); case log([AgentRunService.Item]) }
        let kind: Kind
    }

    /// Coalesce >2 consecutive status items into a collapsible log group; render
    /// shorter runs (e.g. a lone "Run started") inline.
    private var blocks: [Block] {
        var result: [Block] = []
        var pending: [AgentRunService.Item] = []

        func flushPending() {
            if pending.count > 2, let first = pending.first {
                result.append(Block(id: first.id, kind: .log(pending)))
            } else {
                result.append(contentsOf: pending.map { Block(id: $0.id, kind: .item($0)) })
            }
            pending.removeAll()
        }

        for item in agent.transcript {
            if item.kind == .status {
                pending.append(item)
            } else {
                flushPending()
                result.append(Block(id: item.id, kind: .item(item)))
            }
        }
        flushPending()
        return result
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block.kind {
        case .item(let item): itemView(item)
        case .log(let items): logGroup(id: block.id, items: items)
        }
    }

    // MARK: Collapsible log group

    @ViewBuilder
    private func logGroup(id: UUID, items: [AgentRunService.Item]) -> some View {
        let expanded = expandedLogs.contains(id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if expanded { expandedLogs.remove(id) } else { expandedLogs.insert(id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Pipeline logs (\(items.count))").font(.caption2.weight(.medium))
                    if !expanded, let last = items.last {
                        Text("· \(last.text)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        Text(item.text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 15)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Items

    @ViewBuilder
    private func itemView(_ item: AgentRunService.Item) -> some View {
        switch item.kind {
        case .user:
            bubble(align: .trailing, tint: .accentColor.opacity(0.18)) { Text(item.text).font(.callout) }
        case .assistant:
            bubble(align: .leading, tint: .gray.opacity(0.16)) {
                MarkdownText(item.text).textSelection(.enabled)
            }
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

    private func bubble<Content: View>(
        align: HorizontalAlignment,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let trailing = align == .trailing
        return HStack {
            if trailing { Spacer(minLength: 24) }
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint))
                .frame(maxWidth: 280, alignment: trailing ? .trailing : .leading)
            if !trailing { Spacer(minLength: 24) }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}
