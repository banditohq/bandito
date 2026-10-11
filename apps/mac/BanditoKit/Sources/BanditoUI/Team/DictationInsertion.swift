import Foundation

/// Where the dictated text sits in the draft, in UTF-16 units (what the field's selection uses). `lead` is the space
/// that goes before the first word when the caret follows a word.
struct DictationSpan: Equatable {
    var location: Int
    var length: Int
    var lead: String

    /// The caret after the dictated text.
    var end: Int { location + length }
}

/// Puts the dictated text into the draft at the caret, and replaces it as partial results come in. Pure functions.
enum DictationInsertion {
    /// The span for a dictation that starts with the caret at `caret` (nil: at the end of the draft).
    static func start(in draft: String, caret: Int?) -> DictationSpan {
        let text = draft as NSString
        let at = min(max(caret ?? text.length, 0), text.length)
        var lead = ""
        if at > 0, let before = text.substring(with: NSRange(location: at - 1, length: 1)).first, !before.isWhitespace {
            lead = " "
        }
        return DictationSpan(location: at, length: 0, lead: lead)
    }

    /// The draft with the span's text replaced by `partial` (with the lead in front). Returns the new draft and the span
    /// that now covers the dictated text. An empty partial leaves nothing in the draft.
    static func update(_ draft: String, span: DictationSpan, partial: String) -> (draft: String, span: DictationSpan) {
        let text = draft as NSString
        let location = min(max(span.location, 0), text.length)
        let length = min(max(span.length, 0), text.length - location)
        let inserted = partial.isEmpty ? "" : span.lead + partial
        let result = text.replacingCharacters(in: NSRange(location: location, length: length), with: inserted)
        return (result, DictationSpan(location: location, length: inserted.utf16.count, lead: span.lead))
    }
}
