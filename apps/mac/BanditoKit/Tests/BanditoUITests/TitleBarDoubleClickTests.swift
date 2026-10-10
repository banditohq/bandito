import Testing

@testable import BanditoUI

@Suite struct TitleBarDoubleClickTests {
    @Test func zoomIsTheDefaultWhenTheSystemHasNoValue() {
        #expect(TitleBarDoubleClick.action(for: nil) == .zoom)
    }

    @Test func maximizeAndFillZoomTheWindow() {
        #expect(TitleBarDoubleClick.action(for: "Maximize") == .zoom)
        #expect(TitleBarDoubleClick.action(for: "Fill") == .zoom)
    }

    @Test func minimizeMinimizesTheWindow() {
        #expect(TitleBarDoubleClick.action(for: "Minimize") == .minimize)
    }

    @Test func noneDoesNothing() {
        #expect(TitleBarDoubleClick.action(for: "None") == .none)
    }

    @Test func anUnknownValueFallsBackToZoom() {
        #expect(TitleBarDoubleClick.action(for: "SomethingNew") == .zoom)
    }
}
