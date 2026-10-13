import Foundation

/// A guess of how tall a row will be, from what it holds. Only used for rows the list has not measured yet (see
/// `ThreadListView`); it has to be roughly right and always the same for the same row.
public enum ThreadHeightGuess {
    /// Characters of a line of message text at the usual width, and the height of a line with its spacing.
    public static let charsPerLine = 80
    public static let lineHeight: CGFloat = 21.5
    public static let codeLineHeight: CGFloat = 17.5
    /// A bubble's padding plus the gap under a message that is reserved for its action row.
    public static let bubbleChrome: CGFloat = 20 + 16

    public static func height(of row: ThreadRow) -> CGFloat {
        switch row {
        case .day: 36
        case .chapter: 64
        case .toolGroup: 44
        case .browserRun: 96
        case .item(let item): height(of: item)
        }
    }

    private static func height(of item: ThreadItem) -> CGFloat {
        switch item {
        case .user(_, let text, _, _, _, let files):
            text.isEmpty ? 96 : textHeight(text) + CGFloat(files.count) * 40
        case .assistant(_, let text, _), .streaming(let text):
            textHeight(text)
        case .note, .runtimeSwitch, .scheduleRun, .quietTurn: 34
        case .approval: 150
        case .form: 230
        case .connect: 130
        case .chapter: 64
        case .tool: 44
        }
    }

    /// Lines of running text and of code, counted without parsing Markdown.
    public static func textHeight(_ text: String) -> CGFloat {
        var lines: CGFloat = 0
        var codeLines: CGFloat = 0
        var inCode = false
        var run = 0
        var ticks = 0
        func endLine() {
            if inCode {
                codeLines += 1
            } else if ticks < 3 {
                lines += CGFloat(max(1, (run + charsPerLine - 1) / charsPerLine))
            }
            run = 0
            ticks = 0
        }
        for byte in text.utf8 {
            if byte == 10 {
                // A line that starts with a fence opens or closes a code block.
                if ticks >= 3 { inCode.toggle() }
                endLine()
            } else {
                if byte == 96, ticks == run { ticks += 1 }
                run += 1
            }
        }
        if ticks >= 3 { inCode.toggle() }
        endLine()
        let code: CGFloat = codeLines > 0 ? codeLines * codeLineHeight + 40 : 0
        return max(44, lines * lineHeight + code + bubbleChrome)
    }
}
