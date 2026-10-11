import Testing

@testable import BanditoUI

@Suite struct ThreadJumpRulesTests {
    // MARK: the capsule's caption

    @Test func noNewMessagesShowTheArrowAlone() {
        #expect(ThreadJumpRules.caption(unseen: 0) == .arrowOnly)
        #expect(ThreadJumpRules.caption(unseen: -3) == .arrowOnly)
    }

    @Test func newMessagesShowTheirCount() {
        #expect(ThreadJumpRules.caption(unseen: 1) == .count(1))
        #expect(ThreadJumpRules.caption(unseen: 99) == .count(99))
    }

    @Test func moreThanTheCapReadsAsOverflow() {
        #expect(ThreadJumpRules.caption(unseen: 100) == .overflow)
        #expect(ThreadJumpRules.caption(unseen: 5000) == .overflow)
    }

    @Test func aMessageIsCountedOnlyAwayFromTheBottomAndOutsideTheFollowOfASend() {
        #expect(ThreadJumpRules.countsAsUnseen(atBottom: false, sendPinned: false))
        #expect(!ThreadJumpRules.countsAsUnseen(atBottom: true, sendPinned: false))
        // The person's own message and the answer to it are looked at, not counted.
        #expect(!ThreadJumpRules.countsAsUnseen(atBottom: false, sendPinned: true))
        #expect(!ThreadJumpRules.countsAsUnseen(atBottom: true, sendPinned: true))
    }

    @Test func theCapsuleKeepsAShortFadeUnderReducedMotion() {
        #expect(ThreadJumpRules.animation(reduced: true) != ThreadJumpRules.animation(reduced: false))
    }

    // MARK: the follow after a send

    @Test func noFollowWithoutASend() {
        #expect(!ThreadFollowRules.holds(pinned: false, leavesBottom: false, distance: 0, secondsSinceSend: 5))
        #expect(!ThreadFollowRules.holds(pinned: false, leavesBottom: true, distance: 500, secondsSinceSend: 5))
    }

    @Test func theFollowSurvivesGrowthAndLayoutSettling() {
        // Content grows below (the bottom moves away) without a scroll up: it holds, however far the bottom is.
        #expect(ThreadFollowRules.holds(pinned: true, leavesBottom: false, distance: 900, secondsSinceSend: 0.1))
        #expect(ThreadFollowRules.holds(pinned: true, leavesBottom: false, distance: 900, secondsSinceSend: 10))
    }

    @Test func aSmallMoveUpDoesNotEndTheFollow() {
        let small = ThreadFollowRules.deliberateDistance
        #expect(ThreadFollowRules.holds(pinned: true, leavesBottom: true, distance: small, secondsSinceSend: 5))
        #expect(ThreadFollowRules.holds(pinned: true, leavesBottom: true, distance: 3, secondsSinceSend: 5))
    }

    @Test func aClearScrollUpEndsTheFollow() {
        let far = ThreadFollowRules.deliberateDistance + 1
        #expect(!ThreadFollowRules.holds(pinned: true, leavesBottom: true, distance: far, secondsSinceSend: 5))
    }

    @Test func nothingEndsTheFollowInTheFirstMomentsAfterTheSend() {
        // The animated scroll to the new message is under way: its frames are not the person scrolling.
        let fresh = ThreadFollowRules.settle / 2
        #expect(ThreadFollowRules.holds(pinned: true, leavesBottom: true, distance: 4000, secondsSinceSend: fresh))
        #expect(
            !ThreadFollowRules.holds(
                pinned: true, leavesBottom: true, distance: 4000, secondsSinceSend: ThreadFollowRules.settle))
    }

    @Test func theScrollToAMessageHasNoAnimationUnderReducedMotion() {
        #expect(ThreadFollowRules.scrollAnimation(reduced: true) == nil)
        #expect(ThreadFollowRules.scrollAnimation(reduced: false) != nil)
    }

    // MARK: the panel beside the chat

    @Test func theChatGivesRoomOnlyToAPanelBesideIt() {
        #expect(WorkbenchLayout.chatInset(open: true, covers: false, panelWidth: 460) == 460)
        #expect(WorkbenchLayout.chatInset(open: false, covers: false, panelWidth: 460) == 0)
        // Over the chat the panel takes no room from it.
        #expect(WorkbenchLayout.chatInset(open: true, covers: true, panelWidth: 460) == 0)
        #expect(WorkbenchLayout.chatInset(open: false, covers: true, panelWidth: 460) == 0)
    }

    @Test func theInsetChangesOnceForAnOpenAndOnceForAClose() {
        // Five quick toggles end where the last one says: the inset follows `open` alone, no state of its own.
        var open = false
        var insets: [Double] = []
        for _ in 0..<5 {
            open.toggle()
            insets.append(WorkbenchLayout.chatInset(open: open, covers: false, panelWidth: 460))
        }
        #expect(insets == [460, 0, 460, 0, 460])
    }
}
