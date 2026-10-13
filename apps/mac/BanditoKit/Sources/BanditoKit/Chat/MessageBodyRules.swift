import Foundation

/// Where a streaming message splits into the part that will not change and the part being written. Pure, tested.
public enum StreamingSplit {
    /// The end of the last blank line (`\n\n`) that is outside a code fence, or nil when there is none (or the text
    /// is short enough to parse whole).
    public static func stableEnd(of text: String) -> String.Index? {
        guard text.utf8.count > 400 else { return nil }
        var fenceOpen = false
        var lastSplit: String.Index?
        var index = text.startIndex
        var lineStart = true
        while index < text.endIndex {
            let character = text[index]
            if lineStart, text[index...].hasPrefix("```") { fenceOpen.toggle() }
            if character == "\n" {
                let next = text.index(after: index)
                if !fenceOpen, next < text.endIndex, text[next] == "\n" {
                    lastSplit = text.index(after: next)
                }
                lineStart = true
            } else if character != " " {
                lineStart = false
            }
            index = text.index(after: index)
        }
        guard let lastSplit, lastSplit < text.endIndex else { return nil }
        return lastSplit
    }

}

/// Whether a code block scrolls sideways. Pure.
public enum CodeBlockLayout {
    /// The longest line that fits a narrow bubble without a scroll (12.5 pt mono is about 7.5 pt a character; an agent's
    /// bubble in the narrowest window is about 400 pt).
    public static let fittingLine = 48

    public static func needsScroll(_ code: String) -> Bool {
        code.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.count > fittingLine }
    }
}
