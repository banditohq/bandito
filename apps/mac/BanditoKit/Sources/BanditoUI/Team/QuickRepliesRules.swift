import BanditoKit
import BanditoL10n
import Foundation

/// What the row of quick replies under the agent's last message shows and does (docs/ARCHITECTURE.md#quick-replies).
/// Pure: the row draws it, and the tests pin it. The daemon checks the same limits; the app does not trust them.
enum QuickRepliesRules {
    /// Most buttons drawn, and the longest label, in characters.
    static let maxButtons = 4
    static let labelLimit = 40

    /// A button as drawn: its label on one line, cut to the limit; its reply is what is sent, as it came.
    struct Shown: Equatable, Identifiable {
        var id: Int
        var label: String
        var reply: String
        /// The first button is the primary one.
        var isPrimary: Bool
        /// What a pointer over the button tells when the label is not the whole reply.
        var help: String?
    }

    /// The buttons to draw. A button with no label or no reply is not drawn, because pressing it could send nothing.
    static func buttons(_ replies: QuickReplies) -> [Shown] {
        var out: [Shown] = []
        for button in replies.buttons {
            let label = oneLine(button.label)
            let reply = button.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !reply.isEmpty, out.count < maxButtons else { continue }
            let shown = label.count > labelLimit ? String(label.prefix(labelLimit - 1)) + "…" : label
            out.append(
                Shown(id: out.count, label: shown, reply: reply, isPrimary: out.isEmpty, help: reply == shown ? nil : reply))
        }
        return out
    }

    /// A link button's label (one line, cut), or `nil` when the link is not one the app opens.
    static func link(_ replies: QuickReplies) -> (label: String, url: URL)? {
        guard let link = replies.link, let url = webURL(link.url) else { return nil }
        let label = oneLine(link.label)
        guard !label.isEmpty else { return nil }
        return (label.count > labelLimit ? String(label.prefix(labelLimit - 1)) + "…" : label, url)
    }

    /// An address the app opens from an agent's button: https, with a host, no user name, no spaces. Anything else
    /// (`http`, `file`, `javascript`, `https://user@host`) is not a link.
    static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
            let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    /// "2 of 6", or `nil` for a progress that makes no sense.
    static func progressText(_ progress: QuickReplyProgress?) -> String? {
        guard let progress, progress.isValid else { return nil }
        return L10n.QuickReplies.progress(done: String(progress.done), total: String(progress.total))
    }

    /// What the row shows: nothing once a button of this set was pressed (it hides at once, before the reply comes back
    /// as the person's message), and nothing when no button can be drawn.
    static func shown(_ replies: QuickReplies?, pressed: String?) -> QuickReplies? {
        guard let replies, replies.id != pressed, !buttons(replies).isEmpty else { return nil }
        return replies
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
