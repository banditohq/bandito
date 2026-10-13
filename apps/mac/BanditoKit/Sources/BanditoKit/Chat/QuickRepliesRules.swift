import BanditoL10n
import Foundation

/// What the row of quick replies under the agent's last message shows and does (docs/ARCHITECTURE.md#quick-replies).
/// Pure: the row draws it, and the tests pin it. The daemon checks the same limits; the app does not trust them.
public enum QuickRepliesRules {
    /// Most buttons drawn, and the longest label, in characters.
    public static let maxButtons = 4
    public static let labelLimit = 40

    /// A button as drawn: its label on one line, cut to the limit; its reply is what is sent, as it came.
    public struct Shown: Equatable, Identifiable {
        public var id: Int
        public var label: String
        public var reply: String
        /// The first button is the primary one.
        public var isPrimary: Bool
        /// What a pointer over the button tells when the label is not the whole reply: all of the reply.
        public var help: String?
        /// A second line in small print under the label: the reply, cut, when it is not the label. What a click sends
        /// is on the button, so a label cannot stand for other words.
        public var subtitle: String?
    }

    /// Longest second line, in characters.
    public static let subtitleLimit = 48

    /// The buttons to draw. A button with no label or no reply is not drawn, because pressing it could send nothing.
    public static func buttons(_ replies: QuickReplies) -> [Shown] {
        var out: [Shown] = []
        for button in replies.buttons {
            let label = oneLine(button.label)
            let reply = button.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !reply.isEmpty, out.count < maxButtons else { continue }
            let shown = label.count > labelLimit ? String(label.prefix(labelLimit - 1)) + "…" : label
            let differs = reply.caseInsensitiveCompare(label) != .orderedSame
            let subtitle = reply.count > subtitleLimit ? String(reply.prefix(subtitleLimit - 1)) + "…" : reply
            out.append(
                Shown(
                    id: out.count, label: shown, reply: reply, isPrimary: out.isEmpty, help: differs ? reply : nil,
                    subtitle: differs ? subtitle : nil))
        }
        return out
    }

    /// A link button's label (one line, cut), or `nil` when the link is not one the app opens.
    public static func link(_ replies: QuickReplies) -> (label: String, host: String, url: URL)? {
        guard let link = replies.link, let url = webURL(link.url), let host = host(of: url) else { return nil }
        let label = oneLine(link.label)
        guard !label.isEmpty else { return nil }
        return (label.count > labelLimit ? String(label.prefix(labelLimit - 1)) + "…" : label, host, url)
    }

    /// The host a link goes to, as the person reads it next to the label: without a leading `www.`.
    public static func host(of url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The host as drawn: all of it, or, when it is very long, its end (the part that tells whose site it is).
    public static func shownHost(_ host: String) -> String {
        host.count > 32 ? "…" + host.suffix(31) : host
    }

    /// "Open settings · mail.google.com": the label and where it leads.
    public static func caption(label: String, host: String) -> String { "\(label) · \(host)" }

    /// An address the app opens from an agent's button: https, with a host, no user name, no spaces. Anything else
    /// (`http`, `file`, `javascript`, `https://user@host`) is not a link.
    public static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
            let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    /// "2 of 6", or `nil` for a progress that makes no sense.
    public static func progressText(_ progress: QuickReplyProgress?) -> String? {
        guard let progress, progress.isValid else { return nil }
        return L10n.QuickReplies.progress(done: String(progress.done), total: String(progress.total))
    }

    /// What the row shows: nothing once a button of this set was pressed (it hides at once, before the reply comes back
    /// as the person's message), and nothing when no button can be drawn.
    public static func shown(_ replies: QuickReplies?, pressed: String?) -> QuickReplies? {
        guard let replies, replies.id != pressed, !buttons(replies).isEmpty else { return nil }
        return replies
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
