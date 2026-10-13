import Foundation

/// One block of a message as the iPhone chat draws it. Inline marks (bold, italic, code, links) stay in the text and
/// are read by the renderer (`AttributedString(markdown:)` with inline syntax only).
public enum ChatBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// `marker` is what stands before the text: a bullet, `1.`, or a ballot box for a task. `depth` is 0 for the
    /// first level (indentation counted in pairs of spaces, at most 3).
    case listItem(marker: String, depth: Int, text: String)
    case quote(String)
    case rule
    case code(language: String?, code: String, closed: Bool)
}

/// Reads the Markdown of a message into blocks: headings, lists, quotes, rules, paragraphs and fenced code. Pure; the
/// fences are found by `MessageBlocks`, so a stream with an open fence is a code block that is not closed yet.
public enum ChatMarkdown {
    /// The blocks of `text`. A person's own message (`markdown: false`) is kept as typed: paragraphs and code blocks
    /// only.
    public static func parse(_ text: String, markdown: Bool) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        for block in MessageBlocks.parse(text) {
            switch block {
            case .code(let language, let code, let closed):
                blocks.append(.code(language: language, code: code, closed: closed))
            case .text(let running):
                if markdown {
                    blocks.append(contentsOf: parseText(running))
                } else {
                    blocks.append(.paragraph(running))
                }
            }
        }
        return blocks
    }

    /// Whether the text has anything to draw besides plain running text (a heading, a list, a code block): a message
    /// that is one plain paragraph takes the quick path.
    public static func isPlain(_ blocks: [ChatBlock]) -> Bool {
        blocks.count == 1 && { if case .paragraph = blocks[0] { return true } else { return false } }()
    }

    // MARK: text blocks

    private static func parseText(_ text: String) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            blocks.append(.code(language: nil, code: table.joined(separator: "\n"), closed: true))
            table = []
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushTable()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                continue
            }
            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushTable()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                flushQuote()
                table.append(raw)
                continue
            }
            if let item = listItem(raw) {
                flushAll()
                blocks.append(item)
                continue
            }
            flushQuote()
            flushTable()
            // An indented line right after a list item continues that item (a wrapped line of the item).
            if paragraph.isEmpty, case .listItem(let marker, let depth, let itemText)? = blocks.last,
                raw.first == " " || raw.first == "\t"
            {
                blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: itemText + "\n" + trimmed)
                continue
            }
            paragraph.append(trimmed)
        }
        flushAll()
        return blocks
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first) else { return false }
        return trimmed.allSatisfy { $0 == first || $0 == " " } && trimmed.filter { $0 == first }.count >= 3
    }

    private static func heading(_ trimmed: String) -> ChatBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: hashes, text: text)
    }

    /// `- x`, `* x`, `+ x`, `1. x`, `1) x`, with `[ ]` and `[x]` for tasks.
    private static func listItem(_ raw: String) -> ChatBlock? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let body = raw.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return nil }
        var marker: String
        var rest: Substring
        if "-*+".contains(first) {
            let after = body.dropFirst()
            guard after.first == " " else { return nil }
            marker = "•"
            rest = after.dropFirst()
        } else if first.isASCII, first.isNumber {
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            let after = body.dropFirst(digits.count)
            guard digits.count <= 9, let punctuation = after.first, punctuation == "." || punctuation == ")",
                after.dropFirst().first == " "
            else { return nil }
            marker = "\(digits)."
            rest = after.dropFirst(2)
        } else {
            return nil
        }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[ ]") {
            marker = "☐"
            text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix("[x]") || text.hasPrefix("[X]") {
            marker = "☑"
            text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return .listItem(marker: marker, depth: min(3, indent / 2), text: text)
    }
}

/// Where a link in a message may go on the iPhone: web addresses open in the in-app Safari view, file paths stay text.
public enum ChatLinkSafety {
    /// The address when `url` is a plain web link (`http` or `https`, with a host).
    public static func webURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// The first web link of a text: a Markdown link or a bare address.
    public static func firstWebLink(in text: String) -> URL? {
        ChatLinks.find(in: text).lazy.compactMap { link -> URL? in
            if case .url(let address) = link.target { return URL(string: address).flatMap(webURL) }
            return nil
        }.first
    }
}
