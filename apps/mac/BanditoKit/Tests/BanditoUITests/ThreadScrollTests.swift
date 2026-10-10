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

    private func m(distance: Int, offset: Int, content: Int, height: Int = 800) -> ThreadScrollMetrics {
        ThreadScrollMetrics(distance: distance, height: height, offset: offset, contentHeight: content)
    }

    @Test func metricsAreRoundedToWholePoints() {
        let metrics = ThreadScrollMetrics(offset: 99.6, contentHeight: 1500.2, height: 800.2)
        #expect(metrics.offset == 100)
        #expect(metrics.contentHeight == 1500)
        #expect(metrics.height == 800)
        #expect(metrics.distance == 600)
    }

    @Test func jumpButtonWithoutDistanceFollowsTheBottomMarker() {
        #expect(ThreadScroll.showsJump(atBottom: false, distance: nil))
        #expect(!ThreadScroll.showsJump(atBottom: true, distance: nil))
    }

    @Test func jumpButtonShowsMoreThan120PointsAway() {
        #expect(ThreadScroll.showsJump(atBottom: false, distance: 121))
        #expect(ThreadScroll.showsJump(atBottom: false, distance: 1500))
        #expect(!ThreadScroll.showsJump(atBottom: false, distance: 120), "exactly 120 is not more")
        #expect(!ThreadScroll.showsJump(atBottom: false, distance: 60))
    }

    @Test func jumpButtonStaysHiddenWhileFollowing() {
        #expect(!ThreadScroll.showsJump(atBottom: true, distance: 900))
    }

    @Test func within48PointsIsAtTheBottom() {
        let at = ThreadScroll.atBottom(was: false, old: nil, new: m(distance: 48, offset: 500, content: 1348))
        #expect(at)
        let far = ThreadScroll.atBottom(was: false, old: nil, new: m(distance: 49, offset: 500, content: 1349))
        #expect(!far)
    }

    @Test func contentGrowingBelowKeepsTheBottom() {
        let old = m(distance: 0, offset: 500, content: 1300)
        let grown = m(distance: 400, offset: 500, content: 1700)
        #expect(ThreadScroll.atBottom(was: true, old: old, new: grown))
    }

    @Test func aResizedPanelKeepsTheBottom() {
        let old = m(distance: 0, offset: 500, content: 1300)
        let narrower = m(distance: 300, offset: 500, content: 1600, height: 800)
        #expect(ThreadScroll.atBottom(was: true, old: old, new: narrower))
        let shorter = m(distance: 100, offset: 500, content: 1300, height: 700)
        #expect(ThreadScroll.atBottom(was: true, old: old, new: shorter))
    }

    @Test func smallScrollUpIsNotUndoneByTheNextChunk() {
        let atEnd = m(distance: 0, offset: 500, content: 1300)
        let up = m(distance: 30, offset: 470, content: 1300)
        #expect(!ThreadScroll.atBottom(was: true, old: atEnd, new: up))
        let chunk = m(distance: 40, offset: 470, content: 1310)
        let still = ThreadScroll.atBottom(was: false, old: up, new: chunk)
        #expect(!still)
        #expect(!ThreadScroll.shouldFollow(atBottom: still, old: up, new: chunk))
        let down = m(distance: 0, offset: 510, content: 1310)
        #expect(ThreadScroll.atBottom(was: false, old: chunk, new: down))
    }

    @Test func aRowNotLoadedFallsBackToTheBottom() {
        #expect(ThreadScroll.resolved(.row("x"), rowIDs: ["a", "b"]) == .bottom)
        #expect(ThreadScroll.resolved(.row("a"), rowIDs: ["a", "b"]) == .row("a"))
        #expect(ThreadScroll.resolved(.bottom, rowIDs: []) == .bottom)
    }

    @Test func scrollingUpLeavesTheBottomAndStaysAway() {
        let old = m(distance: 0, offset: 500, content: 1300)
        let up = m(distance: 200, offset: 300, content: 1300)
        #expect(!ThreadScroll.atBottom(was: true, old: old, new: up))
        // The stream grows on while the person reads above: still away.
        let grown = m(distance: 600, offset: 300, content: 1700)
        #expect(!ThreadScroll.atBottom(was: false, old: up, new: grown))
    }

    @Test func reachingTheBottomAgainReturnsToIt() {
        let up = m(distance: 200, offset: 300, content: 1300)
        let down = m(distance: 20, offset: 480, content: 1300)
        #expect(ThreadScroll.atBottom(was: false, old: up, new: down))
    }

    @Test func scrollingDownTowardsTheBottomKeepsFollowing() {
        // The animated jump to the bottom: the offset only rises, the bottom is still far for a moment.
        let old = m(distance: 600, offset: 100, content: 1500)
        let mid = m(distance: 300, offset: 400, content: 1500)
        #expect(ThreadScroll.atBottom(was: true, old: old, new: mid))
    }

    @Test func contentShrinkingAtTheBottomStaysAtTheBottom() {
        let old = m(distance: 0, offset: 700, content: 1500)
        let shrunk = m(distance: 0, offset: 500, content: 1300)
        #expect(ThreadScroll.atBottom(was: true, old: old, new: shrunk))
    }

    @Test func followsWhenTheLayoutGrowsAtTheBottom() {
        let old = m(distance: 0, offset: 500, content: 1300)
        let grown = m(distance: 120, offset: 500, content: 1420)
        #expect(ThreadScroll.shouldFollow(atBottom: true, old: old, new: grown))
    }

    @Test func doesNotFollowWhenTheBottomIsAlreadyOnScreen() {
        let old = m(distance: 0, offset: 500, content: 1300)
        let same = m(distance: 1, offset: 500, content: 1301)
        #expect(!ThreadScroll.shouldFollow(atBottom: true, old: old, new: same))
    }

    @Test func doesNotFollowAPlainScrollOrAwayFromTheBottom() {
        let old = m(distance: 0, offset: 500, content: 1300)
        let scrolled = m(distance: 30, offset: 470, content: 1300)
        #expect(!ThreadScroll.shouldFollow(atBottom: true, old: old, new: scrolled), "no layout change, no follow")
        let grown = m(distance: 400, offset: 300, content: 1500)
        #expect(!ThreadScroll.shouldFollow(atBottom: false, old: old, new: grown))
        #expect(!ThreadScroll.shouldFollow(atBottom: true, old: nil, new: grown))
    }

    @Test func emptyThreadNeitherFollowsNorShowsJump() {
        let empty = m(distance: 0, offset: 0, content: 0)
        #expect(ThreadScroll.atBottom(was: true, old: nil, new: empty))
        #expect(!ThreadScroll.shouldFollow(atBottom: true, old: empty, new: empty))
        #expect(!ThreadScroll.showsJump(atBottom: true, distance: 0))
    }

    @Test func topRowIsTheHighestRowBelowTheOffset() {
        let spans = [
            "a": ThreadRowSpan(minY: 0, maxY: 100), "b": ThreadRowSpan(minY: 112, maxY: 300),
            "c": ThreadRowSpan(minY: 312, maxY: 400),
        ]
        #expect(ThreadScroll.topRow(spans: spans, offset: 0, valid: ["a", "b", "c"]) == "a")
        #expect(ThreadScroll.topRow(spans: spans, offset: 150, valid: ["a", "b", "c"]) == "b")
        #expect(ThreadScroll.topRow(spans: spans, offset: 100, valid: ["a", "b", "c"]) == "b", "a ends at the offset")
        #expect(ThreadScroll.topRow(spans: spans, offset: 150, valid: ["a", "c"]) == "c", "gone rows do not count")
        #expect(ThreadScroll.topRow(spans: spans, offset: 900, valid: ["a", "b", "c"]) == nil)
        #expect(ThreadScroll.topRow(spans: [:], offset: 0, valid: ["a"]) == nil)
    }

    @Test func windowShowsTheLast300AndKeepsItsStart() {
        let ids = (0..<1000).map { "r\($0)" }
        #expect(ThreadScroll.windowStart(ids: ids, startID: nil) == 700)
        #expect(ThreadScroll.windowStart(ids: ids, startID: "r400") == 400, "a pinned start does not slide")
        #expect(ThreadScroll.windowStart(ids: ids, startID: "gone") == 700)
        #expect(ThreadScroll.windowStart(ids: Array(ids.prefix(10)), startID: nil) == 0)
        #expect(ThreadScroll.windowStart(ids: [], startID: nil) == 0)
    }

    @Test func windowWidensBy300AndStopsAtTheFirstRow() {
        #expect(ThreadScroll.widenedStart(from: 700) == 400)
        #expect(ThreadScroll.widenedStart(from: 100) == 0)
        #expect(ThreadScroll.widenedStart(from: 0) == 0)
    }

    @Test func windowAtTheBottomStaysWithin600WhileItemsAreAppended() {
        var start = 0
        for count in 1...1000 {
            start = ThreadScroll.slidStart(count: count, start: start, atBottom: true)
            #expect(count - start <= 2 * ThreadScroll.windowSize)
        }
        #expect(1000 - start >= ThreadScroll.windowSize)
    }

    @Test func windowAwayFromTheBottomDoesNotMove() {
        var start = 0
        for count in 1...1000 {
            start = ThreadScroll.slidStart(count: count, start: start, atBottom: false)
        }
        #expect(start == 0)
    }

    @Test func nearTopIsWithin300Points() {
        #expect(ThreadScroll.nearTop(offset: 0))
        #expect(ThreadScroll.nearTop(offset: 300))
        #expect(!ThreadScroll.nearTop(offset: 301))
    }

    @Test func unseenCountIsTheGrowthOfTheThread() {
        #expect(ThreadScroll.unseenAdded(previousCount: 10, currentCount: 13) == 3)
        #expect(ThreadScroll.unseenAdded(previousCount: 13, currentCount: 13) == 0)
        #expect(ThreadScroll.unseenAdded(previousCount: 13, currentCount: 10) == 0)
    }
}
