import BanditoKit
import Foundation

/// A message split into running text and fenced code blocks.
public enum MessageBlock: Equatable, Sendable {
    case text(String)
    /// `closed` is false for a fence that never ends (a reply still streaming in).
    case code(language: String?, code: String, closed: Bool)
}

/// Reading of a message's Markdown that the bubbles need: the code blocks (each gets a copy button), and the text
/// without Markdown marks. Pure functions.
public enum MessageBlocks {
    public static func parse(_ text: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var running: [Substring] = []
        var fence: Fence?
        var code: [Substring] = []

        func flushText() {
            let joined = running.joined(separator: "\n").trimmingCharacters(in: .newlines)
            running.removeAll()
            if !joined.isEmpty { blocks.append(.text(joined)) }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                if open.closes(line) {
                    blocks.append(.code(language: open.language, code: code.joined(separator: "\n"), closed: true))
                    code.removeAll()
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if let opened = Fence(opening: line) {
                flushText()
                fence = opened
            } else {
                running.append(line)
            }
        }
        if let open = fence {
            blocks.append(.code(language: open.language, code: code.joined(separator: "\n"), closed: false))
        } else {
            flushText()
        }
        return blocks
    }

    /// Whether the message has a code block.
    public static func hasCode(_ text: String) -> Bool {
        parse(text).contains { if case .code = $0 { return true } else { return false } }
    }

    /// The message as plain text: Markdown marks (emphasis, inline code, links, heading hashes) are left out, code blocks keep
    /// their content without the fences.
    public static func plainText(_ text: String) -> String {
        parse(text).map { block -> String in
            switch block {
            case .code(_, let code, _): return code
            case .text(let running):
                return running.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { plainLine(String($0)) }
                    .joined(separator: "\n")
            }
        }
        .joined(separator: "\n\n")
    }

    private static func plainLine(_ line: String) -> String {
        var line = line
        let trimmed = line.drop(while: { $0 == " " })
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
            line = String(trimmed.dropFirst(hashes + 1))
        }
        guard
            let rendered = try? AttributedString(
                markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return line }
        return String(rendered.characters)
    }

    /// The first `limit` characters of a message for a quote or a reply bar, on one line, with an ellipsis when cut.
    public static func excerpt(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// An opening or closing fence line: three or more backticks or tildes, indented by at most three spaces.
    private struct Fence {
        var mark: Character
        var length: Int
        var language: String?

        init?(opening line: Substring) {
            let indent = line.prefix(while: { $0 == " " }).count
            guard indent <= 3 else { return nil }
            let rest = line.dropFirst(indent)
            guard let first = rest.first, first == "`" || first == "~" else { return nil }
            let run = rest.prefix(while: { $0 == first }).count
            guard run >= 3 else { return nil }
            let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
            // A backtick fence's info string has no backticks: ```code``` on one line is inline code.
            if first == "`", info.contains("`") { return nil }
            mark = first
            length = run
            let word = info.split(separator: " ").first.map(String.init)
            language = (word?.isEmpty ?? true) ? nil : word
        }

        func closes(_ line: Substring) -> Bool {
            let indent = line.prefix(while: { $0 == " " }).count
            guard indent <= 3 else { return false }
            let rest = line.dropFirst(indent)
            let run = rest.prefix(while: { $0 == mark }).count
            guard run >= length else { return false }
            return rest.dropFirst(run).allSatisfy { $0 == " " }
        }
    }
}

/// What the person may put on a message.
public enum ReactionRules {
    /// The six emoji offered first.
    public static let common = ["👍", "❤️", "😂", "🔥", "👀", "✅"]

    /// The daemon's check (`check_emoji`): one grapheme cluster of at most 16 bytes, no spaces.
    public static func isValid(_ emoji: String) -> Bool {
        emoji.count == 1 && emoji.utf8.count <= 16 && !emoji.contains(where: \.isWhitespace)
    }

    /// A character the system emoji picker could have produced: valid for the daemon and drawn as a picture
    /// (a letter or a digit typed into the field is not).
    public static func isPickable(_ character: Character) -> Bool {
        let text = String(character)
        guard isValid(text) else { return false }
        return character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F
                || (scalar.properties.isEmoji && scalar.value >= 0x203C)
        }
    }

    /// The first emoji in text the system picker put into a field, if any.
    public static func firstEmoji(in text: String) -> String? {
        text.first(where: isPickable).map(String.init)
    }
}

/// The text a reply bar and a quote show.
public enum ReplyQuote {
    /// Characters of the original shown in the bar above the composer.
    public static let barLimit = 120
}

/// The message being answered, held while the person writes the reply.
public struct ReplyTarget: Equatable, Sendable {
    /// `seq` of the original message.
    public var seq: Int64
    /// The original is the person's own message.
    public var fromUser: Bool
    public var text: String

    public init(seq: Int64, fromUser: Bool, text: String) {
        self.seq = seq
        self.fromUser = fromUser
        self.text = text
    }

    /// The bar's one-line text.
    public var excerpt: String { MessageBlocks.excerpt(MessageBlocks.plainText(text), limit: ReplyQuote.barLimit) }
}
