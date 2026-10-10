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
}
