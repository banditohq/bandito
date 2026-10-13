import BanditoDesign
import BanditoKit
import SwiftUI

// The rules themselves are in BanditoKit (`ThreadJumpRules`, `ThreadFollowRules`); this file holds their motion.
extension ThreadJumpRules {
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

extension ThreadFollowRules {
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
