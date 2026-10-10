import BanditoDesign
import SwiftUI

/// The rendered page of a Markdown file, in the mockup's style. Checkboxes are buttons: a tap reports the
/// source line so the caller can flip it in the text.
struct MarkdownPreview: View {
    let source: String
    var onToggleCheckbox: (Int) -> Void = { _ in }
    /// Reading mode: no card around the page; the text sits in a centered column at most 720 pt wide.
    var isBare = false

    var body: some View {
        if isBare {
            ScrollView {
                MarkdownPage(source: source, insets: EdgeInsets(), onToggleCheckbox: onToggleCheckbox)
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
            }
        } else {
            card
        }
    }

    private var card: some View {
        ScrollView {
            MarkdownPage(source: source, onToggleCheckbox: onToggleCheckbox)
        }
        .background(
            LinearGradient(colors: [Color(hex: 0x1C1814), Color(hex: 0x171411)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.Bandito.text.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The page itself, without scrolling, so it can be drawn offline (snapshots).
struct MarkdownPage: View {
    let source: String
    /// Space around the text inside the page.
    var insets = EdgeInsets(top: 26, leading: 32, bottom: 26, trailing: 32)
    var onToggleCheckbox: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownParser.parse(source).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, onToggle: onToggleCheckbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(insets)
        .textSelection(.enabled)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let onToggle: (Int) -> Void

    private static let purple = Color(hex: 0xC8B6E8)
    private static let signal = Color(hex: 0xFF8A1F)

    var body: some View {
        switch block {
        case .heading(let level, let text, _):
            heading(level: level, text: text)
        case .paragraph(let text, _):
            Text(MarkdownInline.attributed(text))
                .font(BanditoFont.text(size: 14.5, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .item(let text, let line, let checkbox, let number):
            item(text: text, line: line, checkbox: checkbox, number: number)
        case .code(let language, let text, _):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language)
                        .font(BanditoFont.text(size: 10.5, weight: 600))
                        .foregroundStyle(Color.Bandito.text3)
                }
                Text(text)
                    .font(BanditoFont.mono(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Color(hex: 0x0E0C0B), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .quote(let text, _):
            // The bar is an overlay so it takes the height of the text, not of the whole stack.
            Text(MarkdownInline.attributed(text))
                .font(BanditoFont.text(size: 13.5, weight: 400))
                .foregroundStyle(Self.purple)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.leading, 24)
                .padding(.trailing, 14)
                .background(Self.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.purple)
                        .frame(width: 3)
                        .padding(.leading, 14)
                        .padding(.vertical, 8)
                }
        }
    }

    @ViewBuilder
    private func heading(level: Int, text: String) -> some View {
        switch level {
        case 1:
            Text(MarkdownInline.attributed(text))
                .font(BanditoFont.text(size: 26, weight: 700))
                .foregroundStyle(Color.Bandito.text)
                .padding(.bottom, 4)
        case 2:
            Text(MarkdownInline.attributed(text))
                .font(BanditoFont.text(size: 13, weight: 600))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(Self.signal)
                .padding(.top, 6)
        default:
            Text(MarkdownInline.attributed(text))
                .font(BanditoFont.text(size: 15, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func item(text: String, line: Int, checkbox: Bool?, number: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let checked = checkbox {
                Button {
                    onToggle(line)
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(checked ? Self.signal : Color.Bandito.text3)
                }
                .banditoButton(.row(cornerRadius: 4, hoverOpacity: 0.08))
            } else if let number {
                Text(number)
                    .font(BanditoFont.text(size: 14.5, weight: 400)).monospacedDigit()
                    .foregroundStyle(Color.Bandito.text3)
            } else {
                Text("•")
                    .font(BanditoFont.text(size: 14.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Text(MarkdownInline.attributed(text))
                .font(BanditoFont.text(size: 14.5, weight: 400))
                .strikethrough(checkbox == true)
                .foregroundStyle(checkbox == true ? Color.Bandito.text3 : Color.Bandito.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Inline Markdown (bold, code, links) through Foundation, with code spans set in the mockup's amber.
enum MarkdownInline {
    static func attributed(_ text: String) -> AttributedString {
        var result =
            (try? AttributedString(
                markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = BanditoFont.mono(size: 12.5)
            result[run.range].foregroundColor = Color(hex: 0xFFB067)
            result[run.range].backgroundColor = Color(hex: 0xFF8A1F).opacity(0.09)
        }
        return result
    }
}
