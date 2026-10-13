import Foundation

/// Rules of the "to the newest" capsule and of the follow after the person's own message. Pure, so tested alone.
public enum ThreadJumpRules {
    /// The count shown on the capsule stops here: more reads "99+ new".
    public static let countCap = 99

    /// What the capsule says next to its arrow.
    public enum Caption: Equatable, Sendable {
        /// Nothing came in: the arrow alone.
        case arrowOnly
        /// "3 new".
        case count(Int)
        /// "99+ new".
        case overflow
    }

    public static func caption(unseen: Int) -> Caption {
        if unseen <= 0 { return .arrowOnly }
        return unseen > countCap ? .overflow : .count(unseen)
    }

    /// Whether messages that came in count as "new" for the capsule. Not while the person follows the bottom, and not
    /// right after their own send: their message and its answer are looked at, not counted.
    public static func countsAsUnseen(atBottom: Bool, sendPinned: Bool) -> Bool {
        !atBottom && !sendPinned
    }
}

/// How the thread follows the bottom after the person sent a message.
public enum ThreadFollowRules {
    /// A scroll up of this many points, at least, away from the bottom is the person's own; a smaller move is a layout
    /// settling (rows rising in, the composer changing height, rounding) and keeps the follow.
    public static let deliberateDistance = 64
    /// For this long after the send, even a deliberate-looking move is ignored: the animated scroll to the new message
    /// is still under way and its first frames must not end the follow.
    public static let settle: Double = 0.35

    /// Whether the follow after a send goes on. It ends only when the person scrolls up themselves: the scroll leaves
    /// the bottom, the bottom is a clear distance away, and the send is not fresh.
    public static func holds(pinned: Bool, leavesBottom: Bool, distance: Int, secondsSinceSend: Double) -> Bool {
        guard pinned else { return false }
        guard leavesBottom else { return true }
        if secondsSinceSend < settle { return true }
        return distance <= deliberateDistance
    }
}
