import SwiftUI

/// Renders the markdown Claude actually sends into compact SwiftUI blocks.
///
/// A completed notice carries the assistant's whole reply, up to
/// `PetState.completedDetailLimit` (4000) characters of real markdown — the
/// message that produced this card had 5 `##` headings, 16 `**` pairs, two
/// code fences and 34 inline-code spans. Dropped into a plain `Text` (what the
/// card used to do) every one of those markers shows up literally.
///
/// Deliberately small: this is a 320pt card, not a document viewer. Block
/// types are the ones Claude actually emits — heading, paragraph, bullet,
/// numbered item, fenced code — and everything inline (`**bold**`, `` `code` ``,
/// links) is handed to `AttributedString`'s own markdown parser.
struct MarkdownText: View {
    let text: String
    var font: Font = .caption2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(Self.blocks(of: text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let content):
            Text(inline(content))
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let content):
            Text(inline(content))
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let content):
            HStack(alignment: .top, spacing: 5) {
                Text(marker)
                    .font(font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(inline(content))
                    .font(font)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code(let content):
            Text(content)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
    }

    /// Inline markup only — bold/italic/code/links — leaving the block layout
    /// above to do the rest. Falls back to the raw line if parsing fails.
    private func inline(_ line: String) -> AttributedString {
        (try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(line)
    }

    /// Inline-only markdown for the short model-written strings that aren't
    /// whole documents — a question, an option's description. They regularly
    /// carry `**emphasis**` and `` `code` ``, which a plain `Text` prints as
    /// asterisks and backticks.
    static func inlineOnly(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }

    // MARK: - Blocks

    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
        case listItem(marker: String, content: String)
        case code(String)
    }

    /// Splits the message into blocks. Consecutive plain lines join into one
    /// paragraph (Claude hard-wraps prose), fenced code is kept verbatim, and
    /// an unterminated fence still closes at the end of the text so a truncated
    /// message can't swallow the rest of the card.
    static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inFence = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }
        func flushCode() {
            if !code.isEmpty {
                blocks.append(.code(code.joined(separator: "\n")))
                code.removeAll()
            }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                if !inFence { flushCode() } else { flushParagraph() }
                continue
            }
            if inFence {
                code.append(String(raw))
                continue
            }
            if line.isEmpty { flushParagraph(); continue }
            if line.hasPrefix("#") {
                flushParagraph()
                blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let bullet = ["- ", "* ", "• "].first(where: { line.hasPrefix($0) }) {
                flushParagraph()
                blocks.append(.listItem(marker: "•", content: String(line.dropFirst(bullet.count))))
                continue
            }
            if let dot = line.firstIndex(of: "."), dot > line.startIndex,
               line[line.startIndex..<dot].allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flushParagraph()
                blocks.append(.listItem(
                    marker: String(line[line.startIndex...dot]),
                    content: String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        flushCode()   // an unclosed fence still renders as code
        return blocks
    }
}
