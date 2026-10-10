#if os(macOS)
import AppKit

/// Puts a line break into the message field that has keyboard focus, at the caret, replacing any selection. Shift+Return
/// and Option+Return use this: the field's own handling of them selects text instead of breaking the line.
@MainActor
enum FieldNewline {
    static func insert() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        editor.insertText("\n", replacementRange: editor.selectedRange())
    }
}
#endif
