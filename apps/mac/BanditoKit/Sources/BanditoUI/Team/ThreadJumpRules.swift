import BanditoDesign
import SwiftUI

/// Rules of the "to the newest" capsule and of the follow after the person's own message. Pure, so tested alone.
enum ThreadJumpRules {
    /// The count shown on the capsule stops here: more reads "99+ new".
    static let countCap = 99

    /// What the capsule says next to its arrow.
    enum Caption: Equatable {
        /// Nothing came in: the arrow alone.
        case arrowOnly
        /// "3 new".
        case count(Int)
        /// "99+ new".
        case overflow
    }

    static func caption(unseen: Int) -> Caption {
        if unseen <= 0 { return .arrowOnly }
        return unseen > countCap ? .overflow : .count(unseen)
    }

    /// Whether messages that came in count as "new" for the capsule. Not while the person follows the bottom, and not
    /// right after their own send: their message and its answer are looked at, not counted.
    static func countsAsUnseen(atBottom: Bool, sendPinned: Bool) -> Bool {
        !atBottom && !sendPinned
    }

    /// The capsule's spring (the same family as the mode bar's and the empty state's).
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// How far the capsule travels when it comes in or goes out.
    static let travel: CGFloat = 14

    /// How the capsule comes and goes: a slide up with a fade, or a fade alone while motion is reduced.
    static func transition(reduced: Bool) -> AnyTransition {
        if reduced { return .opacity }
        return .asymmetric(
            insertion: .offset(y: travel).combined(with: .opacity),
            removal: .offset(y: travel).combined(with: .opacity))
    }

    /// The animation of the capsule: the spring, or a short fade while motion is reduced.
    static func animation(reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: BanditoMotion.fast) : spring
    }
}

/// How the thread follows the bottom after the person sent a message.
enum ThreadFollowRules {
    /// A scroll up of this many points, at least, away from the bottom is the person's own; a smaller move is a layout
    /// settling (rows rising in, the composer changing height, rounding) and keeps the follow.
    static let deliberateDistance = 64
    /// For this long after the send, even a deliberate-looking move is ignored: the animated scroll to the new message
    /// is still under way and its first frames must not end the follow.
    static let settle: Double = 0.35

    /// Whether the follow after a send goes on. It ends only when the person scrolls up themselves: the scroll leaves
    /// the bottom, the bottom is a clear distance away, and the send is not fresh.
    static func holds(pinned: Bool, leavesBottom: Bool, distance: Int, secondsSinceSend: Double) -> Bool {
        guard pinned else { return false }
        guard leavesBottom else { return true }
        if secondsSinceSend < settle { return true }
        return distance <= deliberateDistance
    }

    /// The slide to the person's own message: soft, none while motion is reduced.
    static func scrollAnimation(reduced: Bool) -> ThreadSlide? {
        reduced ? nil : ThreadSlide(duration: BanditoMotion.slow, curve: [0.2, 0.8, 0.2, 1])
    }
}

/// How the thread's list slides to a place: how long, along which cubic curve (its two control points).
struct ThreadSlide: Equatable {
    var duration: Double
    var curve: [Float]

    static let easeOut: [Float] = [0, 0, 0.58, 1]
}
