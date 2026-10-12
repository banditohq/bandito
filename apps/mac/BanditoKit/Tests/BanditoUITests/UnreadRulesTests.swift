import Testing

@testable import BanditoUI

/// When a chat counts as looked at (its replies are read), and the text of a badge.
@Suite struct UnreadRulesTests {
    @Test func aChatIsLookedAtOnScreenInAnActiveWindowAtTheNewest() {
        #expect(UnreadRules.isLookedAt(onScreen: true, hidden: false, windowActive: true, atBottom: true, sendPinned: false))
    }

    @Test func aChatIsNotLookedAtWhenItIsOffScreenHiddenOrInAnInactiveWindow() {
        #expect(!UnreadRules.isLookedAt(onScreen: false, hidden: false, windowActive: true, atBottom: true, sendPinned: false))
        #expect(!UnreadRules.isLookedAt(onScreen: true, hidden: true, windowActive: true, atBottom: true, sendPinned: false))
        #expect(!UnreadRules.isLookedAt(onScreen: true, hidden: false, windowActive: false, atBottom: true, sendPinned: false))
    }

    @Test func aChatScrolledUpDoesNotLookAtNewReplies() {
        #expect(!UnreadRules.isLookedAt(onScreen: true, hidden: false, windowActive: true, atBottom: false, sendPinned: false))
    }

    @Test func aChatFollowingAfterASendCountsAsLookedAtLikeTheNewCapsule() {
        // The same rule as the "new" capsule (ThreadJumpRules.countsAsUnseen): after the person's own send the
        // reply is looked at, not counted.
        #expect(UnreadRules.isLookedAt(onScreen: true, hidden: false, windowActive: true, atBottom: false, sendPinned: true))
    }

    @Test func badgeShowsTheCountUpTo99AndAPlusAbove() {
        #expect(UnreadRules.badge(0) == nil)
        #expect(UnreadRules.badge(-2) == nil)
        #expect(UnreadRules.badge(1) == "1")
        #expect(UnreadRules.badge(99) == "99")
        #expect(UnreadRules.badge(100) == "99+")
        #expect(UnreadRules.badge(5000) == "99+")
    }
}
