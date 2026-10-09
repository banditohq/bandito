import SwiftUI
import Testing

@testable import BanditoUI

@Suite struct GitHubMarkTests {
    /// The Octicon is 16 wide and about 15.6 high: its tail stops short of the bottom of the box.
    @Test func markFillsItsSixteenUnitFrame() {
        let box = GitHubMark().path(in: CGRect(x: 0, y: 0, width: 16, height: 16)).boundingRect
        #expect(abs(box.minX) < 0.05 && abs(box.minY) < 0.05)
        #expect(abs(box.width - 16) < 0.05)
        #expect(box.height > 15 && box.height <= 16)
    }

    @Test func markScalesToTheFrameItIsGiven() {
        let box = GitHubMark().path(in: CGRect(x: 10, y: 20, width: 32, height: 32)).boundingRect
        #expect(abs(box.minX - 10) < 0.1 && abs(box.minY - 20) < 0.1)
        #expect(abs(box.width - 32) < 0.1)
        #expect(box.height > 30 && box.height <= 32)
    }

    @Test func arcEndsOnItsTarget() {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 8))
        SVGPathParser.addArc(
            to: &path, from: CGPoint(x: 0, y: 8), rx: 8, ry: 8, rotationDegrees: 0, largeArc: false, sweep: true,
            to: CGPoint(x: 16, y: 8))
        let end = path.currentPoint ?? .zero
        #expect(abs(end.x - 16) < 0.01 && abs(end.y - 8) < 0.01)
    }
}

@Suite struct SVGPathParserTests {
    @Test func emptyAndGarbageInputGiveAnEmptyPath() {
        var empty = SVGPathParser("")
        #expect(empty.parse().isEmpty)
        var garbage = SVGPathParser("hello world 12 @@")
        #expect(garbage.parse().isEmpty)
    }

    @Test func parsingStopsAtTheFirstBrokenCommandAndKeepsWhatCameBefore() {
        var parser = SVGPathParser("M0 0 L10 0 L10 10 X 1 2 L5 5")
        let box = parser.parse().boundingRect
        #expect(abs(box.width - 10) < 0.01 && abs(box.height - 10) < 0.01)
    }

    @Test func truncatedArgumentsDoNotCrash() {
        var parser = SVGPathParser("M0 0 C1 2 3")
        _ = parser.parse()
        var arc = SVGPathParser("M0 0 A8 8 0 1")
        _ = arc.parse()
        var flag = SVGPathParser("M0 0 A8 8 0 2 1 16 8")
        _ = flag.parse()
    }
}
