import Foundation

/// The text of a problem report and the link that opens it on GitHub. Pure: the sheet collects the facts
/// (`ProblemDiagnostics`), this builds the text, and the tests hold the rules.
enum ProblemReport {
    /// Where an issue is opened. The template is `.github/ISSUE_TEMPLATE/bug_report.yml`; its field ids are the
    /// parameters below (GitHub fills an issue form from query parameters named like its fields).
    static let issuesURL = "https://github.com/banditohq/bandito/issues/new"
    static let template = "bug_report.yml"

    /// The longest address handed to the browser, in characters once encoded. Browsers take far more; GitHub refuses
    /// an address beyond about 8 000.
    static let maxURLLength = 6_000

    /// The headings of the report. English: it is read by whoever helps. `parse` finds the parts by them.
    enum Heading {
        static let what = "## What happened"
        static let expected = "## What I expected"
        static let diagnostics = "## Diagnostics"
    }

    /// What the report says in place of the diagnostics when they went to the clipboard.
    static let pasteNote = "The diagnostics are too long for a link. They are on the clipboard: paste them here."

    /// The report from the person's two answers and, when attached, the diagnostics.
    static func text(what: String, expected: String, diagnostics: String?) -> String {
        var parts = [
            Heading.what + "\n" + trimmed(what, or: "(not described)"),
            Heading.expected + "\n" + trimmed(expected, or: "(not described)"),
        ]
        if let diagnostics, !diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(Heading.diagnostics + "\n" + diagnostics.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private static func trimmed(_ value: String, or fallback: String) -> String {
        let cut = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? fallback : cut
    }

    /// The three parts of a report text (that may have been edited): what is under each heading. A text without the
    /// headings is all "what".
    struct Parts: Equatable {
        var what = ""
        var expected = ""
        var diagnostics = ""
    }

    static func parse(_ report: String) -> Parts {
        enum Part { case what, expected, diagnostics }
        var parts = Parts()
        var current = Part.what
        var lines: [Part: [Substring]] = [:]
        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            switch line.trimmingCharacters(in: .whitespaces) {
            case Heading.what: current = .what
            case Heading.expected: current = .expected
            case Heading.diagnostics: current = .diagnostics
            default: lines[current, default: []].append(line)
            }
        }
        func join(_ part: Part) -> String {
            (lines[part] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        parts.what = join(.what)
        parts.expected = join(.expected)
        parts.diagnostics = join(.diagnostics)
        return parts
    }

    /// The title of the issue: the first line of what happened, cut at a word, or a plain one.
    static func title(what: String) -> String {
        let first = what.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let line = first.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return "Problem report" }
        guard line.count > 70 else { return line }
        let cut = String(line.prefix(70))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 40 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }

    /// What opening the report needs: the address, and the text to put on the clipboard when the address could not
    /// carry the diagnostics.
    struct Link: Equatable {
        var url: URL
        /// Not nil when the address could not carry everything: the diagnostics (or, when the answers did not fit
        /// either, the whole report), to paste into the issue.
        var clipboard: String?
    }

    /// The address that opens the issue form with the parts filled in. When the encoded address would be longer than
    /// `maxURLLength`, the diagnostics are left out of it (the form says to paste them) and they go to `clipboard`.
    /// When the person's two answers are too long as well, they are shortened in the address and the whole report goes
    /// to the clipboard.
    static func link(report: String, limit: Int = maxURLLength) -> Link? {
        let parts = parse(report)
        let title = title(what: parts.what)
        if let url = url(title: title, parts: parts), url.absoluteString.count <= limit {
            return Link(url: url, clipboard: nil)
        }
        let note = parts.diagnostics.isEmpty ? "" : pasteNote
        let withNote = Parts(what: parts.what, expected: parts.expected, diagnostics: note)
        if !parts.diagnostics.isEmpty, let url = url(title: title, parts: withNote), url.absoluteString.count <= limit {
            return Link(url: url, clipboard: parts.diagnostics)
        }
        // The answers, shortened until the address fits.
        var keep = max(parts.what.count, parts.expected.count)
        while keep > 80 {
            keep = keep * 3 / 4
            let short = Parts(what: shortened(parts.what, to: keep), expected: shortened(parts.expected, to: keep), diagnostics: note)
            if let url = url(title: title, parts: short), url.absoluteString.count <= limit {
                return Link(url: url, clipboard: report)
            }
        }
        let least = Parts(what: shortened(parts.what, to: 80), expected: "", diagnostics: pasteNote)
        return url(title: title, parts: least).map { Link(url: $0, clipboard: report) }
    }

    private static func shortened(_ text: String, to length: Int) -> String {
        text.count <= length ? text : String(text.prefix(length)) + "…"
    }

    private static func url(title: String, parts: Parts) -> URL? {
        var items = [("template", template), ("title", title)]
        if !parts.what.isEmpty { items.append(("what", parts.what)) }
        if !parts.expected.isEmpty { items.append(("expected", parts.expected)) }
        if !parts.diagnostics.isEmpty { items.append(("diagnostics", parts.diagnostics)) }
        let query = items.map { "\($0.0)=\(percentEncoded($0.1))" }.joined(separator: "&")
        return URL(string: issuesURL + "?" + query)
    }

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
