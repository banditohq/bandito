import Foundation

/// Hides what must not leave the Mac in a problem report: tokens and keys, passwords in settings, addresses and
/// hosts, e-mails and the home folder. Pure and conservative: when a piece looks like a secret it is hidden, and the
/// person sees the result before anything is sent (`ReportProblemSheet`). The marker is the same in every language,
/// so a maintainer reading the report knows what it means.
struct SecretRedactor: Sendable {
    /// What replaces a hidden piece.
    static let mark = "‹скрыто›"

    /// Words of this Mac and its person (user name, computer name, server names): hidden wherever they appear, whole
    /// words only, whatever the case. Short ones (under 3 letters) are left, so a name like "al" cannot eat words.
    var terms: [String] = []

    init(terms: [String] = []) {
        self.terms = terms
    }

    /// Hosts that are Bandito's or the report's own and are not private.
    private static let publicHosts: Set<String> = ["bandito.dev", "github.com", "www.github.com", "localhost"]

    /// The text with every secret replaced by `mark`.
    func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for rule in Self.rules {
            out = rule.apply(to: out)
        }
        out = Self.hidingIPv6(out)
        out = Self.hidingHosts(out)
        out = hidingTerms(out)
        return out
    }

    // MARK: rules

    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
            // The patterns are literals of this file: one that does not compile is a bug found by the first test.
            // swiftlint:disable:next force_try
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }

        func apply(to text: String) -> String {
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
        }
    }

    private static let m = NSRegularExpression.escapedTemplate(for: mark)

    /// In this order: the most specific first, the broad ones last.
    private static let rules: [Rule] = [
        // Private keys.
        Rule(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#, m),
        // A password or a token inside a link: scheme://user:secret@host.
        Rule(#"(?<=://)[^\s/@:]+:[^\s/@]+(?=@)"#, m),
        // Bearer tokens (an `Authorization: Basic …` header goes with the settings rule below).
        Rule(#"(?i)\b(Bearer)\s+[A-Za-z0-9._~+/=\-]{8,}"#, "$1 " + m),
        // Known token shapes.
        Rule(#"\bsk-[A-Za-z0-9_\-]{12,}"#, m),
        Rule(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, m),
        Rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, m),
        Rule(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, m),
        Rule(#"\bAKIA[0-9A-Z]{16}\b"#, m),
        Rule(#"\bAIza[0-9A-Za-z_\-]{30,}"#, m),
        Rule(#"\b(?:bdt|bat)_[A-Za-z0-9_\-]{8,}"#, m),
        Rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*"#, m),
        // A Telegram bot key: 123456789:AA…
        Rule(#"\b\d+:[A-Za-z0-9_\-]{30,}"#, m),
        // An authorization header with its scheme word.
        Rule(#"(?i)(authorization["']?\s*[=:]\s*)(?:basic|bearer|digest|token)\s+\S+"#, "$1" + m),
        // A secret in settings or an environment: NAME=value, NAME: value, "name": "value".
        Rule(
            #"(?i)(\b[A-Za-z0-9_.\-]*(?:token(?!s\b)|secret|password|passwd|passphrase|api[_\-]?key|apikey|private[_\-]?key|access[_\-]?key|credential|authorization)[A-Za-z0-9_.\-]*)(["']?\s*[=:]\s*)(?:"[^"\n]*"|'[^'\n]*'|[^\s,;}\]]+)"#,
            "$1$2" + m),
        // The home folder of the person: /Users/name, /home/name, C:\Users\name.
        Rule(#"(?<![A-Za-z0-9])/(?:Users|home)/[^/\s"'<>:]+"#, m),
        Rule(#"(?i)\b[A-Z]:\\Users\\[^\\\s"'<>]+"#, m),
        // E-mail addresses.
        Rule(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#, m),
        // Hardware addresses.
        Rule(#"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b"#, m),
        // IPv4 addresses.
        Rule(#"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#, m),
        // A long mixed token that no rule above knew: 32 letters and digits or more, with all of capitals, small
        // letters and digits (a hash or a plain word is not).
        Rule(#"\b(?=[A-Za-z0-9_\-]*[A-Z])(?=[A-Za-z0-9_\-]*[a-z])(?=[A-Za-z0-9_\-]*\d)[A-Za-z0-9_\-]{32,}\b"#, m),
    ]

    // MARK: IPv6 and hosts

    private static let ipv6Candidate = try! NSRegularExpression(
        pattern: #"(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])"#)

    /// IPv6 addresses. A clock time (12:34:56) and a hardware address look alike, so only a form with `::`, or one with
    /// all eight groups, counts.
    static func hidingIPv6(_ text: String) -> String {
        let ns = text as NSString
        let matches = ipv6Candidate.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let piece = ns.substring(with: match.range)
            let groups = piece.components(separatedBy: ":")
            let isAddress = piece.contains("::") ? piece.count >= 3 : (groups.count == 8 && groups.allSatisfy { !$0.isEmpty })
            guard isAddress, let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: mark)
        }
        return out
    }

    private static let hostSuffixes =
        "com|net|org|io|dev|ru|de|fr|es|jp|kr|cn|uk|us|br|eu|info|biz|me|co|ai|pro|xyz|cloud|site|online|tech|top|"
        + "local|lan|internal|home|localdomain|corp|intranet"

    /// A host name after a scheme (`wss://host:7878/path`), and a bare name that ends in a well-known suffix.
    private static let hostAfterScheme = try! NSRegularExpression(
        pattern: #"(?<=://)(?:[^\s/@?#]*@)?(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9\-._]+)"#)
    private static let bareHost = try! NSRegularExpression(
        pattern: #"\b(?:[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?\.)+(?:"# + hostSuffixes + #")\b(?![.\w])"#,
        options: [.caseInsensitive])

    static func hidingHosts(_ text: String) -> String {
        var out = replaceHosts(in: text, using: hostAfterScheme, group: 1)
        out = replaceHosts(in: out, using: bareHost, group: 0)
        return out
    }

    private static func replaceHosts(in text: String, using regex: NSRegularExpression, group: Int) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let range = match.range(at: group)
            guard range.location != NSNotFound else { continue }
            let host = ns.substring(with: range)
            if publicHosts.contains(host.lowercased()) || host == mark { continue }
            guard let swiftRange = Range(range, in: out) else { continue }
            out.replaceSubrange(swiftRange, with: mark)
        }
        return out
    }

    // MARK: this Mac's words

    private func hidingTerms(_ text: String) -> String {
        var out = text
        // Longest first: "Maria Schneider" before "Maria".
        let list = Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 3 })
            .sorted { $0.count > $1.count }
        for term in list {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: NSRegularExpression.escapedTemplate(for: Self.mark))
        }
        return out
    }
}
