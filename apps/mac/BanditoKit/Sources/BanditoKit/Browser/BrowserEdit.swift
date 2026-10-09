import Foundation

/// Edit shortcuts that a page must see as edit commands: ⌘A selects all, ⌘C copies…
/// Chrome's own clipboard is not the Mac's, so paste is sent as text (`Input.insertText`), not as a command.
public enum BrowserEdit: Sendable, Equatable {
    case selectAll, copy, cut, paste, undo, redo

    /// The edit a ⌘ shortcut means, or nil. `key` is the letter as typed (any case).
    public static func shortcut(key: String, command: Bool, shift: Bool) -> BrowserEdit? {
        guard command else { return nil }
        switch key.lowercased() {
        case "a": return .selectAll
        case "c": return .copy
        case "x": return .cut
        case "v": return .paste
        case "z": return shift ? .redo : .undo
        default: return nil
        }
    }

    /// The name Chrome's `Input.dispatchKeyEvent` takes in `commands`. Nil for paste, which is sent as text.
    public var cdpCommandName: String? {
        switch self {
        case .selectAll: "selectAll"
        case .copy: "copy"
        case .cut: "cut"
        case .undo: "undo"
        case .redo: "redo"
        case .paste: nil
        }
    }
}
