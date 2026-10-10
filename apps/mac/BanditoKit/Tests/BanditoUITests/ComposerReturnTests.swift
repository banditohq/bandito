import Testing

@testable import BanditoUI

/// Return in the message field: plain Return sends, Shift and Option with Return make a line break.
@Suite struct ComposerReturnTests {
    @Test func plainReturnSends() {
        #expect(ComposerReturn.action(shift: false, option: false) == .send)
    }

    @Test func shiftReturnMakesALineBreak() {
        #expect(ComposerReturn.action(shift: true, option: false) == .newLine)
    }

    @Test func optionReturnMakesALineBreak() {
        #expect(ComposerReturn.action(shift: false, option: true) == .newLine)
    }

    @Test func shiftOptionReturnMakesALineBreak() {
        #expect(ComposerReturn.action(shift: true, option: true) == .newLine)
    }
}
