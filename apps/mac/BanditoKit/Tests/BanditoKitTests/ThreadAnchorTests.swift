import Testing

@testable import BanditoKit

/// An older page above the screen must not move what the person is reading.
@Suite struct ThreadAnchorTests {
    @Test func theAnchorIsTheFirstRowThatReachesIntoTheScreen() {
        let rows: [(id: String, minY: Double, height: Double)] = [
            ("a", 0, 100), ("b", 100, 100), ("c", 200, 100),
        ]
        let anchor = ThreadAnchor.capture(rows: rows, visibleTop: 150)
        #expect(anchor == ThreadAnchor(rowID: "b", distanceFromTop: -50))
        #expect(ThreadAnchor.capture(rows: rows, visibleTop: 400) == nil)
    }

    @Test func rowsPrependedAboveKeepTheAnchorRowWhereItWas() {
        let anchor = ThreadAnchor(rowID: "b", distanceFromTop: -50)
        // 600 points of older rows came in above: "b" now begins at 700.
        #expect(anchor.offset(rowMinY: 700) == 750)
        // Before: offset 150, row at 100. After: offset 750, row at 700: the row is 50 above the top both times.
        #expect(700 - anchor.offset(rowMinY: 700) == 100 - 150)
    }

    @Test func theOffsetNeverGoesAboveTheStartOfTheContent() {
        let anchor = ThreadAnchor(rowID: "a", distanceFromTop: 300)
        #expect(anchor.offset(rowMinY: 10) == 0)
        // A list that may scroll past its top (a bar over it) keeps the lower bound it was given.
        #expect(anchor.offset(rowMinY: 10, minOffset: -88) == -88)
    }

    @Test func prependedRowsAreCountedAboveTheFirstKnownRow() {
        #expect(ThreadPrepend.count(old: ["c", "d"], new: ["a", "b", "c", "d"]) == 2)
        #expect(ThreadPrepend.count(old: ["c", "d"], new: ["c", "d", "e"]) == 0)
        #expect(ThreadPrepend.count(old: [], new: ["a"]) == 0)
        // The first old row is gone (a stream became a message): the next one is the reference.
        #expect(ThreadPrepend.count(old: ["x", "d"], new: ["a", "b", "d"]) == 2)
    }

    @Test func theAnchorIsKeptOnlyWhileItsRowIs() {
        let anchor = ThreadAnchor(rowID: "b", distanceFromTop: 0)
        #expect(anchor.isKept(in: ["a", "b"]))
        #expect(!anchor.isKept(in: ["a"]))
    }
}
