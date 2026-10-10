#if os(macOS)
import AppKit
import Testing

@testable import BanditoUI

@Suite struct PageInputClickCountTests {
    @Test func onlyMouseButtonEventsCarryAClickCount() {
        #expect(PageInputView.hasClickCount(.leftMouseDown))
        #expect(PageInputView.hasClickCount(.rightMouseUp))
        // Reading `clickCount` of a scroll event raises inside AppKit: the wheel must never ask for it.
        #expect(!PageInputView.hasClickCount(.scrollWheel))
        #expect(!PageInputView.hasClickCount(.mouseMoved))
    }
}
#endif
