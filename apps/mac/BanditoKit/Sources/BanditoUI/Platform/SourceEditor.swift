#if os(macOS)
import AppKit
import SwiftUI

/// Monospaced text editor with a line-number gutter. Markdown gets light highlighting: headings, bold,
/// code spans, quotes, and list markers. Other text is plain.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var highlightsMarkdown: Bool
    var isEditable: Bool

    /// Above this size the highlighter is skipped, to keep typing responsive.
    private static let highlightLimit = 300_000

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = NSColor(calibratedRed: 0.745, green: 0.698, blue: 0.635, alpha: 1)
        textView.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.047, blue: 0.043, alpha: 1)
        textView.insertionPointColor = NSColor(calibratedRed: 1, green: 0.541, blue: 0.122, alpha: 1)
        textView.textContainerInset = NSSize(width: 6, height: 16)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.string = text

        scroll.drawsBackground = true
        scroll.backgroundColor = textView.backgroundColor
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, textView: textView)

        highlight(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        // Our own edits already match the binding; only an outside change (reload, checklist toggle) needs a reset.
        guard textView.string != text else { return }
        let selected = textView.selectedRange()
        textView.string = text
        textView.setSelectedRange(NSRange(location: min(selected.location, text.utf16.count), length: 0))
        highlight(textView)
        scroll.verticalRulerView?.needsDisplay = true
    }

    fileprivate func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.745, green: 0.698, blue: 0.635, alpha: 1),
        ]
        storage.beginEditing()
        storage.setAttributes(base, range: full)
        if highlightsMarkdown, storage.length < Self.highlightLimit {
            MarkdownHighlighter.apply(to: storage)
        }
        storage.endEditing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceEditor

        init(_ parent: SourceEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.highlight(textView)
        }
    }
}

/// Colors Markdown syntax in place. Patterns are line-based, so the cost stays linear in the text.
private enum MarkdownHighlighter {
    static let heading = try! NSRegularExpression(pattern: "^#{1,6} .*$", options: [.anchorsMatchLines])
    static let code = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    static let bold = try! NSRegularExpression(pattern: "\\*\\*[^*\\n]+\\*\\*")
    static let marker = try! NSRegularExpression(pattern: "^\\s*(?:[-*+]|\\d+[.)])(?=\\s)", options: [.anchorsMatchLines])
    static let checkbox = try! NSRegularExpression(pattern: "\\[[ xX]\\]")
    static let quote = try! NSRegularExpression(pattern: "^>.*$", options: [.anchorsMatchLines])

    static func apply(to storage: NSTextStorage) {
        let text = storage.string
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let orange = NSColor(calibratedRed: 1, green: 0.541, blue: 0.122, alpha: 1)
        let amber = NSColor(calibratedRed: 1, green: 0.69, blue: 0.404, alpha: 1)
        let blue = NSColor(calibratedRed: 0.639, green: 0.741, blue: 0.922, alpha: 1)
        let purple = NSColor(calibratedRed: 0.784, green: 0.714, blue: 0.91, alpha: 1)
        let muted = NSColor(calibratedRed: 0.431, green: 0.396, blue: 0.353, alpha: 1)
        let bright = NSColor(calibratedRed: 0.953, green: 0.922, blue: 0.867, alpha: 1)

        let boldFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        for match in heading.matches(in: text, range: whole) {
            storage.addAttributes([.foregroundColor: orange, .font: boldFont], range: match.range)
        }
        for match in quote.matches(in: text, range: whole) {
            storage.addAttribute(.foregroundColor, value: purple, range: match.range)
        }
        for match in code.matches(in: text, range: whole) {
            storage.addAttribute(.foregroundColor, value: blue, range: match.range)
        }
        for match in bold.matches(in: text, range: whole) {
            storage.addAttributes([.foregroundColor: amber, .font: boldFont], range: match.range)
        }
        for match in marker.matches(in: text, range: whole) {
            storage.addAttribute(.foregroundColor, value: muted, range: match.range)
        }
        for match in checkbox.matches(in: text, range: whole) {
            storage.addAttribute(.foregroundColor, value: bright, range: match.range)
        }
    }
}

/// Line numbers down the left edge of a text view. Draws the number of each visible line fragment that
/// starts a line.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) {
        fatalError("LineNumberRuler is built in code only")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return
        }
        let text = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.431, green: 0.396, blue: 0.353, alpha: 1),
        ]
        let origin = convert(NSPoint.zero, from: textView)
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        guard glyphs.length > 0 else { return }
        let firstChar = layoutManager.characterIndexForGlyph(at: glyphs.location)
        // Number of the line that holds the first visible character.
        var number = 1
        if firstChar > 0 {
            number += text.substring(to: firstChar).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        }
        // If that line starts above the view, its number is not drawn and the next line starts with number + 1.
        let firstStartsLine = firstChar == 0 || text.character(at: firstChar - 1) == 10
        var lineNumber = firstStartsLine ? number : number + 1
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, fragmentGlyphs, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphs.location)
            guard charIndex == 0 || text.character(at: charIndex - 1) == 10 else { return }
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + origin.y
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: y), withAttributes: attributes)
            lineNumber += 1
        }
    }
}
#endif

#if !os(macOS)
import SwiftUI

/// Plain monospaced editor for platforms without the AppKit editor.
struct SourceEditor: View {
    @Binding var text: String
    var highlightsMarkdown: Bool
    var isEditable: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12.5, design: .monospaced))
            .disabled(!isEditable)
    }
}
#endif
