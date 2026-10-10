import CoreGraphics
import Testing

@testable import BanditoUI

@Suite struct BanditoSelectLogicTests {
    // MARK: Highlight

    @Test func opensOnTheSelectedRowWhenItIsEnabled() {
        #expect(SelectHighlight.initial(enabled: [true, true, true], selectedIndex: 2) == 2)
    }

    @Test func opensOnTheFirstEnabledRowWhenTheSelectionIsHiddenOrDisabled() {
        #expect(SelectHighlight.initial(enabled: [false, true, true], selectedIndex: 0) == 1)
        #expect(SelectHighlight.initial(enabled: [true, true], selectedIndex: nil) == 0)
        #expect(SelectHighlight.initial(enabled: [true, true], selectedIndex: 7) == 0)
    }

    @Test func noHighlightWhenNothingCanBeChosen() {
        #expect(SelectHighlight.initial(enabled: [false, false], selectedIndex: nil) == nil)
        #expect(SelectHighlight.initial(enabled: [], selectedIndex: nil) == nil)
    }

    @Test func downMovesToTheNextEnabledRowAndSkipsDisabledOnes() {
        let enabled = [true, false, false, true]
        #expect(SelectHighlight.next(from: 0, enabled: enabled) == 3)
    }

    @Test func downStopsAtTheLastEnabledRow() {
        #expect(SelectHighlight.next(from: 2, enabled: [true, true, true]) == 2)
        #expect(SelectHighlight.next(from: 2, enabled: [true, true, true, false]) == 2)
    }

    @Test func downFromNothingIsTheFirstEnabledRow() {
        #expect(SelectHighlight.next(from: nil, enabled: [false, true]) == 1)
    }

    @Test func upMovesToThePreviousEnabledRowAndSkipsDisabledOnes() {
        let enabled = [true, false, false, true]
        #expect(SelectHighlight.previous(from: 3, enabled: enabled) == 0)
    }

    @Test func upStopsAtTheFirstEnabledRow() {
        #expect(SelectHighlight.previous(from: 0, enabled: [true, true]) == 0)
        #expect(SelectHighlight.previous(from: 1, enabled: [false, true]) == 1)
    }

    @Test func upFromNothingIsTheLastEnabledRow() {
        #expect(SelectHighlight.previous(from: nil, enabled: [true, false]) == 0)
    }

    @Test func keysOnAListWithNothingEnabledHighlightNothing() {
        #expect(SelectHighlight.next(from: nil, enabled: [false]) == nil)
        #expect(SelectHighlight.previous(from: nil, enabled: [false]) == nil)
    }

    // MARK: Search

    @Test func searchIsShownOnlyAboveTheThreshold() {
        #expect(!SelectFilter.showsSearch(optionCount: 8))
        #expect(SelectFilter.showsSearch(optionCount: 9))
    }

    @Test func anEmptyQueryShowsEverything() {
        #expect(SelectFilter.matches(query: "  ", title: "Opus", subtitle: nil))
    }

    @Test func searchMatchesTheTitleOrTheSubtitle() {
        #expect(SelectFilter.matches(query: "opus", title: "Opus 5.5", subtitle: nil))
        #expect(SelectFilter.matches(query: "complex", title: "Opus", subtitle: "For complex work"))
        #expect(!SelectFilter.matches(query: "haiku", title: "Opus", subtitle: "For complex work"))
    }

    @Test func searchIgnoresCaseAndAccents() {
        #expect(SelectFilter.matches(query: "ЭКОНОМНО", title: "Sonnet", subtitle: "Экономно для простых задач"))
        #expect(SelectFilter.matches(query: "cafe", title: "Café", subtitle: nil))
    }

    @Test func everyWordOfTheQueryMustBeFound() {
        #expect(SelectFilter.matches(query: "opus complex", title: "Opus", subtitle: "for complex work"))
        #expect(!SelectFilter.matches(query: "opus haiku", title: "Opus", subtitle: "for complex work"))
    }

    // MARK: Size

    @Test func panelWidthFollowsTheFieldWithinLimits() {
        #expect(SelectFilter.panelWidth(fieldWidth: 360) == 360)
        #expect(SelectFilter.panelWidth(fieldWidth: 200) == 280)
        #expect(SelectFilter.panelWidth(fieldWidth: 900) == 520)
    }

    // MARK: Groups

    private func option(_ value: String, subtitle: String? = nil) -> SelectOption<String> {
        SelectOption(value: value, title: value, subtitle: subtitle)
    }

    @Test func groupsKeepTheSectionOrderAndTheOptionsOrder() {
        let sections = [
            SelectSection(title: "A", options: [option("opus"), option("sonnet")]),
            SelectSection(title: "B", options: [option("haiku")]),
        ]
        let groups = SelectFilter.groups(sections, query: "")
        #expect(groups.map(\.title) == ["A", "B"])
        #expect(groups.flatMap(\.options).map(\.value) == ["opus", "sonnet", "haiku"])
    }

    @Test func groupsLeaveOutTheOptionsTheQueryDoesNot() {
        let sections = [
            SelectSection(title: "Main", options: [option("opus", subtitle: "for complex work"), option("haiku")]),
            SelectSection(title: "Other", options: [option("claude-opus-4-8")]),
        ]
        let groups = SelectFilter.groups(sections, query: "complex")
        #expect(groups.map(\.title) == ["Main"])
        #expect(groups.first?.options.map(\.value) == ["opus"])
    }

    @Test func emptySectionsAreDroppedAfterASearch() {
        let sections = [
            SelectSection(title: "Main", options: [option("opus")]),
            SelectSection(title: "Other", options: [option("claude-opus-4-8")]),
        ]
        #expect(SelectFilter.groups(sections, query: "claude").map(\.title) == ["Other"])
        #expect(SelectFilter.groups(sections, query: "nothing-matches").isEmpty)
    }

    // MARK: Field

    @Test func titleOnlyDropsTheSubtitleAndKeepsTheRest() {
        let option = SelectOption(value: 1, title: "Forge", subtitle: "Writes code", icon: "star", monospaced: true)
        let shown = option.titleOnly
        #expect(shown.value == 1)
        #expect(shown.title == "Forge")
        #expect(shown.subtitle == nil)
        #expect(shown.icon == "star")
        #expect(shown.monospaced)
    }
}
