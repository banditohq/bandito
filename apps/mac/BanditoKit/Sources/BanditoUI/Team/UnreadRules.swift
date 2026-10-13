import BanditoKit
import Foundation

/// Rules of the unread counts in the team list: when a chat counts as looked at, and how a count reads on its badge.
/// Pure, so tested alone.
enum UnreadRules {
    /// The chat is looked at now: on screen, not hidden by another mode, in an active window, and following the newest
    /// message. "Following" is the rule of the "new" capsule (`ThreadJumpRules.countsAsUnseen`), so the two never disagree.
    static func isLookedAt(onScreen: Bool, hidden: Bool, windowActive: Bool, atBottom: Bool, sendPinned: Bool) -> Bool {
        onScreen && !hidden && windowActive && !ThreadJumpRules.countsAsUnseen(atBottom: atBottom, sendPinned: sendPinned)
    }

    /// The text of a badge: the count, "99+" above 99, nil for none.
    static func badge(_ count: Int) -> String? {
        if count <= 0 { return nil }
        return count > ThreadJumpRules.countCap ? "\(ThreadJumpRules.countCap)+" : String(count)
    }
}
