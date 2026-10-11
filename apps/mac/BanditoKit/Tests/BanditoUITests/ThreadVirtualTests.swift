import Foundation
import Testing

@testable import BanditoUI

@Suite struct ThreadVirtualTests {
    private func ids(_ count: Int, prefix: String = "r") -> [String] { (0..<count).map { "\(prefix)\($0)" } }

    private func window(_ count: Int, guess: CGFloat = 100) -> ThreadVirtualWindow {
        var window = ThreadVirtualWindow()
        window.setRows(ids: ids(count)) { _ in guess }
        return window
    }

    @Test func aNewThreadBuildsItsNewestRows() {
        let w = window(500)
        #expect(w.range == 484..<500)
        #expect(window(10).range == 0..<10)
        #expect(window(0).range == 0..<0)
    }

    @Test func theSpacesAddUpToTheWholeThread() {
        let w = window(100, guess: 100)
        let range = w.range
        let all = 100 * (100 + ThreadVirtualWindow.rowSpacing) - ThreadVirtualWindow.rowSpacing
        let built = CGFloat(range.count) * (100 + ThreadVirtualWindow.rowSpacing) - ThreadVirtualWindow.rowSpacing
        // The stack puts a gap between a space and the row next to it: one each side.
        let spaces = w.spaceBefore(range.lowerBound) + w.spaceAfter(range.upperBound)
        #expect(abs(spaces + built + ThreadVirtualWindow.rowSpacing - all) < 0.001)
        #expect(w.spaceAfter(100) == 0)
        #expect(w.spaceBefore(0) == 0)
    }

    @Test func measuredHeightsReplaceGuesses() {
        var w = window(100, guess: 100)
        w.record(id: "r5", height: 250)
        #expect(w.height(of: "r5") == 250)
        #expect(w.height(of: "r6") == 100)
        // Ten rows before: nine guesses and the measured one, each with its gap, less the last gap.
        #expect(w.spaceBefore(10) == 1258, "got \(w.spaceBefore(10))")
    }

    @Test func theRangeGrowsUpwardWhenTheScreenNearsItsTop() {
        var w = window(500)
        // Screen at the very top of the built rows: rows above are needed.
        let top = w.top(of: w.range.lowerBound)
        let needed = w.neededRange(offset: top, viewport: 700)
        #expect(needed != nil)
        w.commit(low: needed!.low, high: needed!.high)
        #expect(w.range.lowerBound < 484)
        // The screen is well inside: nothing to change.
        let inside = w.top(of: w.range.lowerBound + 12)
        #expect(w.neededRange(offset: inside, viewport: 700) == nil)
    }

    @Test func rowsBuiltAboveAreComparedWithTheirGuess() {
        var w = window(500, guess: 100)
        let top = w.top(of: w.range.lowerBound)
        let needed = w.neededRange(offset: top, viewport: 700)!
        w.commit(low: needed.low, high: needed.high)
        let firstNew = w.ids[w.range.lowerBound]
        // Taller than guessed: the thread below moved down by the difference.
        let m1 = w.record(id: firstNew, height: 160)
        #expect(m1 == 60)
        // Reported once.
        let m2 = w.record(id: firstNew, height: 160)
        #expect(m2 == nil)
        // A row that was already built is not compared.
        let old = w.ids[499]
        let m3 = w.record(id: old, height: 300)
        #expect(m3 == nil)
        // Exactly as guessed: nothing moved.
        let second = w.ids[w.range.lowerBound + 1]
        let m4 = w.record(id: second, height: 100)
        #expect(m4 == nil)
    }

    @Test func aJumpMovesNothing() {
        var w = window(500)
        let m6 = w.reveal(id: "r100")
        #expect(m6)
        #expect(w.range.contains(100))
        let m5 = w.record(id: "r100", height: 400)
        #expect(m5 == nil)
        // Already built: no change.
        let m7 = w.reveal(id: "r100")
        #expect(!m7)
        let m8 = w.reveal(id: "missing")
        #expect(!m8)
    }

    @Test func rowsAddedAboveKeepTheRange() {
        var w = window(100)
        let before = (w.lowID, w.highID)
        w.setRows(ids: ids(50, prefix: "old") + ids(100)) { _ in 100 }
        #expect((w.lowID, w.highID) == before)
        #expect(w.range.count == 16)
        #expect(w.range.lowerBound == 50 + 84)
    }

    @Test func aThreadAtItsEndKeepsFollowingIt() {
        var w = window(100)
        #expect(w.highID == "r99")
        w.setRows(ids: ids(103)) { _ in 100 }
        #expect(w.highID == "r102")
        // Scrolled up: new rows do not move the range.
        var up = window(500)
        let t = up.top(of: 100)
        let needed = up.neededRange(offset: t, viewport: 700)!
        up.commit(low: needed.low, high: needed.high)
        let high = up.highID
        up.setRows(ids: ids(503)) { _ in 100 }
        #expect(up.highID == high)
    }

    @Test func aThreadThatLostItsRowsStartsAtItsEnd() {
        var w = window(100)
        w.setRows(ids: ids(80, prefix: "other")) { _ in 100 }
        #expect(w.range == 64..<80)
    }

    @Test func anotherWidthForgetsTheHeights() {
        var w = window(100)
        w.setWidth(700)
        w.record(id: "r99", height: 250)
        #expect(w.height(of: "r99") == 250)
        w.setWidth(700.2)
        #expect(w.height(of: "r99") == 250)
        w.setWidth(640)
        #expect(w.height(of: "r99") == 100)
    }

    @Test func theRowOnTopIsFoundFromTheHeights() {
        var w = window(20, guess: 100)
        for i in 0..<20 { w.record(id: "r\(i)", height: i == 3 ? 400 : 100) }
        // Rows: 22 pad, then r0 (100) +12 ... r3 starts at 22 + 3 * 112 = 358, ends 758.
        #expect(w.rowID(atOffset: 0) == "r0")
        #expect(w.rowID(atOffset: 357) == "r3" || w.rowID(atOffset: 357) == "r2")
        #expect(w.rowID(atOffset: 400) == "r3")
        #expect(w.rowID(atOffset: 760) == "r3" || w.rowID(atOffset: 760) == "r4")
        #expect(w.rowID(atOffset: 5000) == "r19")
    }

    @Test func aFarTooLargeRangeIsCutBack() {
        var w = window(2000)
        // Build everything, as a long scroll could have.
        w.commit(low: "r0", high: "r1999")
        let t = w.top(of: 1000)
        let cut = w.neededRange(offset: t, viewport: 700)
        #expect(cut != nil)
        #expect(cut!.low != "r0")
    }

    @Test func theGuessReadsTheTextOfTheRow() {
        let short = ThreadHeightGuess.textHeight("ok")
        let long = ThreadHeightGuess.textHeight(String(repeating: "word ", count: 400))
        let code = ThreadHeightGuess.textHeight("Here:\n\n```swift\nlet a = 1\nlet b = 2\nlet c = 3\n```\n\nDone.")
        #expect(short < long)
        #expect(code > short + 3 * ThreadHeightGuess.codeLineHeight)
        #expect(short >= 44)
    }
}
