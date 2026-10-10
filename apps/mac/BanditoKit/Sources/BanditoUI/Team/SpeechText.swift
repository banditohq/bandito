import Foundation

/// The text an agent's reply is read aloud with: its Markdown turned into plain sentences. A code block is not read; it
/// becomes one phrase (`codeSkipped`, a localised string). Pure functions.
enum SpeechText {
    static func plain(_ markdown: String, codeSkipped: String) -> String {
        MessageBlocks.parse(markdown)
            .map { block -> String in
                switch block {
                case .code:
                    return codeSkipped
                case .text(let running):
                    return running.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { cleanLine(String($0)) }
                        .joined(separator: "\n")
                }
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// One line of running text without its Markdown marks.
    static func cleanLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.range(of: #"^[\s|:-]*-{3,}[\s|:-]*$"#, options: .regularExpression) != nil { return "" }
        text = text.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*\*|__|~~|`"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*([^*\s][^*]*)\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "|", with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }
}
