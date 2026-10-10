import Testing

@testable import BanditoUI

@Suite struct ThreadScrollTests {
    @Test func threadShownForTheFirstTimeStartsAtTheNewestMessage() {
        #expect(ThreadScroll.restoreTarget(nil) == .bottom)
    }

    @Test func threadComesBackToWhereItWasLeft() {
        #expect(ThreadScroll.restoreTarget(.row("r42")) == .row("r42"))
        #expect(ThreadScroll.restoreTarget(.bottom) == .bottom)
    }

    @Test func leavingAtTheBottomKeepsTheBottom() {
        #expect(ThreadScroll.place(atBottom: true, topRowID: "r7") == .bottom)
        #expect(ThreadScroll.place(atBottom: true, topRowID: nil) == .bottom)
    }

    @Test func leavingAboveKeepsTheRowOnTop() {
        #expect(ThreadScroll.place(atBottom: false, topRowID: "r7") == .row("r7"))
    }

    @Test func leavingAboveWithoutAKnownTopRowFallsBackToTheBottom() {
        #expect(ThreadScroll.place(atBottom: false, topRowID: nil) == .bottom)
        #expect(ThreadScroll.place(atBottom: false, topRowID: ThreadScroll.bottomID) == .bottom)
    }

    @Test func jumpButtonWithoutDistanceFollowsTheBottomMarker() {
        #expect(ThreadScroll.showsJump(atBottom: false, distance: nil, screen: nil))
        #expect(!ThreadScroll.showsJump(atBottom: true, distance: nil, screen: nil))
    }

    @Test func jumpButtonShowsOnlyMoreThanOneScreenAway() {
        #expect(ThreadScroll.showsJump(atBottom: false, distance: 1500, screen: 800))
        #expect(!ThreadScroll.showsJump(atBottom: false, distance: 700, screen: 800))
        #expect(!ThreadScroll.showsJump(atBottom: false, distance: 800, screen: 800), "exactly one screen is not more")
    }

    @Test func unseenCountIsTheGrowthOfTheThread() {
        #expect(ThreadScroll.unseenAdded(previousCount: 10, currentCount: 13) == 3)
        #expect(ThreadScroll.unseenAdded(previousCount: 13, currentCount: 13) == 0)
        #expect(ThreadScroll.unseenAdded(previousCount: 13, currentCount: 10) == 0)
    }
}
