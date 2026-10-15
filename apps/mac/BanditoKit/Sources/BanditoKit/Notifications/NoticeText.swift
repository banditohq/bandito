import Foundation

/// The text a notification shows, made from an agent's reply. The same rules as the daemon's push text (`plain` in
/// daemon/src/push.rs), so a local notice and a pushed one read the same: the markdown comes off, every run of
/// whitespace is one space, and the text is cut with an ellipsis.
public enum NoticeText {
    /// The longest text a finished turn's notice shows, in characters.
    public static let limit = 400

    /// `raw` as a notification shows it, cut to `limit` characters.
    public static func plain(_ raw: String, limit: Int) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .map(headingText)
        let collapsed = strippedInline(lines.joined(separator: "\n"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return cut(collapsed, limit)
    }

    /// The text of a finished turn's notice: nil when there is no reply, or it is blank once the markdown is off.
    public static func finishedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = plain(raw, limit: limit)
        return text.isEmpty ? nil : text
    }

    /// A line without its heading mark (`## Итог` is `Итог`); a `#` with no space after it is text.
    private static func headingText(_ line: String) -> String {
        let t = line.drop(while: \.isWhitespace)
        let body = t.drop(while: { $0 == "#" })
        if body.count != t.count, body.first == " " {
            return String(body.drop(while: \.isWhitespace))
        }
        return String(t)
    }

    /// Backticks go; `[text](url)` becomes `text`; a `*` or `_` goes unless it sits between two letters or digits.
    private static func strippedInline(_ s: String) -> String {
        let c = Array(s)
        var out = ""
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "`" {
                i += 1
                continue
            }
            if ch == "[", let link = linkEnd(c, i) {
                out.append(contentsOf: c[(i + 1)..<link.close])
                i = link.end + 1
                continue
            }
            if ch == "*" || ch == "_" {
                let inWord = i > 0 && c[i - 1].isLetterOrNumber && i + 1 < c.count && c[i + 1].isLetterOrNumber
                if !inWord {
                    i += 1
                    continue
                }
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    /// For a `[` at `open`: where its text ends (`]`) and its url (`)`), when `](...)` follows.
    private static func linkEnd(_ c: [Character], _ open: Int) -> (close: Int, end: Int)? {
        guard let close = c[(open + 1)...].firstIndex(of: "]"), close + 1 < c.count, c[close + 1] == "(" else {
            return nil
        }
        guard let end = c[(close + 2)...].firstIndex(of: ")") else { return nil }
        return (close, end)
    }

    /// `s` cut to `max` characters, the last one being `…` when something was cut.
    private static func cut(_ s: String, _ max: Int) -> String {
        guard max > 0 else { return "" }
        guard s.count > max else { return s }
        return String(s.prefix(max - 1)) + "…"
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
