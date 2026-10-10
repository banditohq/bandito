import Foundation
import Testing

@testable import BanditoUI

/// The numbers of the input look: the border and the focus glow.
@Suite struct BanditoFieldLookTests {
    @Test func restingBorderIsEightPercentOfTheTextColor() {
        #expect(BanditoFieldLook.borderOpacity(focused: false) == 0.08)
    }

    @Test func focusedBorderIsThirtyPercentOfTheTextColor() {
        #expect(BanditoFieldLook.borderOpacity(focused: true) == 0.30)
    }

    @Test func glowShowsOnlyWhileFocusedAndValid() {
        #expect(BanditoFieldLook.glowOpacity(focused: true, error: false) == 0.08)
        #expect(BanditoFieldLook.glowOpacity(focused: false, error: false) == 0)
        #expect(BanditoFieldLook.glowOpacity(focused: true, error: true) == 0)
    }

    @Test func fieldIsTenPointCornersAndThirtySixHigh() {
        #expect(BanditoFieldLook.cornerRadius == 10)
        #expect(BanditoFieldLook.minHeight == 36)
    }
}
