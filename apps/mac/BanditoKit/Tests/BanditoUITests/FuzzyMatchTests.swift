import Testing

@testable import BanditoUI

@Suite struct FuzzyMatchTests {
    @Test func prefixBeatsWordStartBeatsSubstring() {
        let prefix = FuzzyMatch.match("fo", in: "Forge")
        let word = FuzzyMatch.match("fo", in: "Billing Forge")
        let inner = FuzzyMatch.match("or", in: "Forge")
        #expect(prefix != nil && word != nil && inner != nil)
        #expect(prefix!.score > word!.score)
        #expect(word!.score > inner!.score)
    }

    @Test func subsequenceIsBelowSubstring() {
        let substring = FuzzyMatch.match("org", in: "forgery")
        let gaps = FuzzyMatch.match("fge", in: "forge")
        #expect(substring != nil && gaps != nil)
        #expect(substring!.score > gaps!.score)
    }

    @Test func highlightsContiguousRange() {
        #expect(FuzzyMatch.match("fo", in: "Forge")?.ranges == [0..<2])
        #expect(FuzzyMatch.match("forge", in: "billing forge")?.ranges == [8..<13])
    }

    @Test func highlightsEachCharacterOfASubsequence() {
        #expect(FuzzyMatch.match("fge", in: "forge")?.ranges == [0..<1, 3..<5])
    }

    @Test func matchIgnoresCaseAndDiacritics() {
        #expect(FuzzyMatch.match("FORGE", in: "forge")?.ranges == [0..<5])
        #expect(FuzzyMatch.match("cafe", in: "Café")?.ranges == [0..<4])
    }

    @Test func noMatchIsNil() {
        #expect(FuzzyMatch.match("xyz", in: "forge") == nil)
    }

    @Test func emptyQueryMatchesWithoutHighlight() {
        let match = FuzzyMatch.match("  ", in: "forge")
        #expect(match != nil)
        #expect(match?.ranges.isEmpty == true)
    }

    @Test func rankingSortsByScoreThenKeepsOrder() {
        let items = ["Billing forge", "Forge", "forgery notes", "xforgex", "nothing"]
        let ranked = FuzzyMatch.rank("forge", items) { $0 }.map(\.item)
        #expect(ranked == ["Forge", "forgery notes", "Billing forge", "xforgex"])
    }
}
