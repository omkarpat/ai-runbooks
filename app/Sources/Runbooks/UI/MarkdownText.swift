import SwiftUI

/// Lightweight markdown renderer for agent replies and generated runbooks.
/// SwiftUI's `Text` only does *inline* markdown (bold/italic/code) and collapses
/// block structure, so this handles the block level — headers, bullet and
/// numbered lists, blank-line spacing — and defers inline styling to
/// `AttributedString`. Enough for our content without a heavy dependency.
struct MarkdownText: View {
    private let markdown: String

    init(_ markdown: String) { self.markdown = markdown }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Color.clear.frame(height: 3)
        } else if line.hasPrefix("### ") {
            inline(String(line.dropFirst(4))).font(.subheadline.weight(.semibold))
        } else if line.hasPrefix("## ") {
            inline(String(line.dropFirst(3))).font(.headline)
        } else if line.hasPrefix("# ") {
            inline(String(line.dropFirst(2))).font(.title3.weight(.bold))
        } else if let numbered = numberedPrefix(line) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(numbered.number).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                inline(numbered.rest).font(.callout)
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(String(line.dropFirst(2))).font(.callout)
            }
        } else {
            inline(line).font(.callout)
        }
    }

    /// Inline bold/italic/code via AttributedString; falls back to plain text.
    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    /// Parse a leading "N. " ordered-list marker.
    private func numberedPrefix(_ s: String) -> (number: String, rest: String)? {
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let digits = s[s.startIndex..<dot]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let after = s.index(after: dot)
        guard after < s.endIndex, s[after] == " " else { return nil }
        return ("\(digits).", String(s[s.index(after: after)...]))
    }
}
