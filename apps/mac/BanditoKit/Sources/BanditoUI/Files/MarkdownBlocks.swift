import Foundation

/// One block of a Markdown document. `line` is the 0-based source line where the block starts, so the
/// preview can point back into the source (checkbox toggles edit that line).
enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String, line: Int)
    case paragraph(text: String, line: Int)
    /// A list item. `checkbox` is `nil` for a plain item, `false` for `- [ ]`, `true` for `- [x]`.
    case item(text: String, line: Int, checkbox: Bool?)
    case code(language: String?, text: String, line: Int)
    case quote(text: String, line: Int)
}

/// A small Markdown reader for the preview: headings, paragraphs, lists with checkboxes, fenced code,
/// and quotes. Inline syntax (bold, code, links) stays in the text and is rendered by the view.
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: (lines: [String], start: Int)?
        /// The last source line consumed by a block; a continuation must start right after it.
        var lastEnd = -2
        var index = 0

        func flushParagraph() {
            guard let open = paragraph else { return }
            blocks.append(.paragraph(text: open.lines.joined(separator: " "), line: open.start))
            paragraph = nil
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = fenceMarker(trimmed) {
                flushParagraph()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                var next = index + 1
                while next < lines.count, !lines[next].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[next])
                    next += 1
                }
                blocks.append(
                    .code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n"), line: index))
                index = next + 1
                lastEnd = next
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.dropFirst(heading)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: heading, text: text, line: index))
                index += 1
                lastEnd = index - 1
                continue
            }

            if let item = listItem(trimmed) {
                flushParagraph()
                blocks.append(.item(text: item.text, line: index, checkbox: item.checkbox))
                lastEnd = index
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case .quote(let previous, let start)? = blocks.last, lastEnd == index - 1 {
                    blocks[blocks.count - 1] = .quote(text: previous + " " + text, line: start)
                } else {
                    blocks.append(.quote(text: text, line: index))
                }
                lastEnd = index
                index += 1
                continue
            }

            // An indented line right after a list item continues that item.
            if case .item(let text, let start, let checkbox)? = blocks.last, lastEnd == index - 1,
                raw.first == " " || raw.first == "\t"
            {
                blocks[blocks.count - 1] = .item(text: text + " " + trimmed, line: start, checkbox: checkbox)
                lastEnd = index
                index += 1
                continue
            }

            if paragraph == nil {
                paragraph = (lines: [trimmed], start: index)
            } else {
                paragraph?.lines.append(trimmed)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    /// `` ``` `` or `~~~` when the line opens a fence.
    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    /// The number of `#` when the line is a heading (1 to 6 `#` and a space), else `nil`.
    private static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return hashes
    }

    /// A bullet (`-`, `*`, `+`) or ordered (`1.`, `1)`) item, with its checkbox state if it has one.
    private static func listItem(_ trimmed: String) -> (text: String, checkbox: Bool?)? {
        guard let marker = listMarkerEnd(trimmed) else { return nil }
        var body = trimmed[marker...].trimmingCharacters(in: .whitespaces)
        var checkbox: Bool?
        if body.hasPrefix("[ ]") {
            checkbox = false
            body = String(body.dropFirst(3))
        } else if body.hasPrefix("[x]") || body.hasPrefix("[X]") {
            checkbox = true
            body = String(body.dropFirst(3))
        }
        return (body.trimmingCharacters(in: .whitespaces), checkbox)
    }

    /// The index just after a list marker and its space, or `nil` if the line has no list marker.
    private static func listMarkerEnd(_ trimmed: String) -> String.Index? {
        guard let first = trimmed.first else { return nil }
        if "-*+".contains(first) {
            let next = trimmed.index(after: trimmed.startIndex)
            guard next < trimmed.endIndex, trimmed[next] == " " else { return nil }
            return next
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let punctuation = trimmed.index(trimmed.startIndex, offsetBy: digits.count)
        guard punctuation < trimmed.endIndex, trimmed[punctuation] == "." || trimmed[punctuation] == ")" else {
            return nil
        }
        let space = trimmed.index(after: punctuation)
        guard space < trimmed.endIndex, trimmed[space] == " " else { return nil }
        return space
    }
}

/// Flips the checkbox on one source line (`- [ ]` ↔ `- [x]`) and returns the new source.
enum MarkdownChecklist {
    /// `nil` when `line` is not a checklist item (or does not exist), so the caller changes nothing.
    static func toggle(_ source: String, line: Int) -> String? {
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(line), let match = lines[line].firstMatch(of: #/^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]/#)
        else { return nil }
        let isChecked = match.output.2 != " "
        lines[line] = String(match.output.1) + (isChecked ? "[ ]" : "[x]") + lines[line][match.range.upperBound...]
        return lines.joined(separator: "\n")
    }
}
