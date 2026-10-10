@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Chapter length choices: the presets, their labels, and which budgets the daemon and the model accept.
@Suite struct ChapterLengthTests {
    @Test func presetsAreTheFiveOffered() {
        #expect(ChapterLength.presets == [60_000, 120_000, 200_000, 500_000, 1_000_000])
        #expect(ChapterLength.presets.contains(ContextUsage.defaultBudget))
    }

    @Test func presetLabelsAreShort() {
        #expect(ChapterLength.label(60_000) == "60K")
        #expect(ChapterLength.label(120_000) == "120K")
        #expect(ChapterLength.label(1_000_000) == "1M")
    }

    @Test func customLabelsKeepOneDecimal() {
        #expect(ChapterLength.label(250_000) == "250K")
        #expect(ChapterLength.label(1_500_000) == "1,5M")
        #expect(ChapterLength.label(250_500) == "250,5K")
        #expect(ChapterLength.label(20_000) == "20K")
    }

    @Test func budgetWithoutAWindowOnlyHasToBeInTheDaemonsRange() {
        #expect(ChapterLength.isAllowed(120_000, window: nil))
        #expect(ChapterLength.isAllowed(20_000, window: nil))
        #expect(ChapterLength.isAllowed(1_000_000, window: nil))
        #expect(!ChapterLength.isAllowed(19_999, window: nil))
        #expect(!ChapterLength.isAllowed(1_000_001, window: nil))
        #expect(!ChapterLength.isAllowed(0, window: nil))
        #expect(!ChapterLength.isAllowed(10_000, window: nil))
        #expect(!ChapterLength.isAllowed(2_000_000, window: nil))
    }

    @Test func budgetAboveTheModelWindowIsNotAllowed() {
        #expect(ChapterLength.isAllowed(200_000, window: 200_000))
        #expect(ChapterLength.isAllowed(120_000, window: 200_000))
        #expect(!ChapterLength.isAllowed(500_000, window: 200_000))
        #expect(!ChapterLength.isAllowed(1_000_000, window: 200_000))
        #expect(ChapterLength.isAllowed(1_000_000, window: 1_000_000))
        #expect(!ChapterLength.isAllowed(1_500_000, window: 1_000_000))
    }

    // MARK: typed custom size

    @Test func typedThousandsWithAFractionBecomeTokens() {
        #expect(ChapterLength.parseThousands("250,5") == 250_500)
        #expect(ChapterLength.parseThousands("250.5") == 250_500)
        #expect(ChapterLength.parseThousands("1.5") == 1_500)
        #expect(ChapterLength.parseThousands("300") == 300_000)
        #expect(ChapterLength.parseThousands("300,") == 300_000)
    }

    @Test func extraDecimalsRoundToAWholeToken() {
        // 1,2345 thousand is 1234.5 tokens: half up, so 1235.
        #expect(ChapterLength.parseThousands("1,2345") == 1_235)
        #expect(ChapterLength.parseThousands("1,2344") == 1_234)
    }

    @Test func textThatIsNotANumberHasNoTokens() {
        #expect(ChapterLength.parseThousands("abc") == nil)
        #expect(ChapterLength.parseThousands("") == nil)
        #expect(ChapterLength.parseThousands(",5") == nil)
        #expect(ChapterLength.parseThousands("1,2,3") == nil)
        #expect(ChapterLength.parseThousands("12a") == nil)
        #expect(ChapterLength.parseThousands("99999999999") == nil)
    }

    @Test func prefillShowsTheSizeInThousandsWithItsFraction() {
        #expect(ChapterLength.thousandsText(250_500) == "250,5")
        #expect(ChapterLength.thousandsText(120_000) == "120")
        #expect(ChapterLength.thousandsText(250_050) == "250,05")
        #expect(ChapterLength.thousandsText(1_000_001) == "1000,001")
    }

    @Test func typingKeepsDigitsAndOneDecimalComma() {
        #expect(ChapterLength.cleanedInput("1.5") == "1,5")
        #expect(ChapterLength.cleanedInput("1,2,3") == "1,23")
        #expect(ChapterLength.cleanedInput("1a2b") == "12")
        #expect(ChapterLength.cleanedInput(",5") == "5")
        #expect(ChapterLength.cleanedInput("1234567890123456") == "123456789012")
    }

    @Test func customSizeSavesOnlyANewValidSize() {
        #expect(ChapterLength.customSize("", current: 120_000, window: nil) == .empty)
        #expect(ChapterLength.customSize("abc", current: 120_000, window: nil) == .invalid)
        #expect(ChapterLength.customSize("0", current: 120_000, window: nil) == .invalid)
        #expect(ChapterLength.customSize("10", current: 120_000, window: nil) == .invalid)
        #expect(ChapterLength.customSize("2000", current: 120_000, window: nil) == .invalid)
        #expect(ChapterLength.customSize("1500", current: 120_000, window: 1_000_000) == .invalid)
        #expect(ChapterLength.customSize("120", current: 120_000, window: nil) == .unchanged(120_000))
        #expect(ChapterLength.customSize("250,5", current: 120_000, window: nil) == .ok(250_500))
        #expect(ChapterLength.customSize("250,5", current: 120_000, window: nil).savable == 250_500)
        #expect(ChapterLength.customSize("120", current: 120_000, window: nil).savable == nil)
    }

    @Test func customSizeAboveTheModelWindowSaysSo() {
        #expect(ChapterLength.customSize("500", current: 120_000, window: 200_000) == .aboveWindow(500_000))
        #expect(ChapterLength.customSize("200", current: 120_000, window: 200_000) == .ok(200_000))
        // The agent already has 1M and the model holds 200K: the same size is still above the window.
        #expect(ChapterLength.customSize("1000", current: 1_000_000, window: 200_000) == .aboveWindow(1_000_000))
    }
}
