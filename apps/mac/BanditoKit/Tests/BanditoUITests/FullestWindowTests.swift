import BanditoL10n
import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct FullestWindowTests {
    private func window(_ name: String, remaining: Double) -> UsageWindowLine {
        UsageWindowLine(id: name, label: name, remaining: remaining, resetsAt: nil, note: nil)
    }

    private func card(_ runtime: String, _ windows: [UsageWindowLine]) -> UsageCard {
        UsageCard(
            runtime: runtime, name: UsageCards.displayName(runtime), plan: nil, color: .peach, who: nil,
            windows: windows)
    }

    @Test func picksTheMostUsedWindowAcrossAllCardsWithoutARuntime() {
        let cards = [
            card("claude", [window("5 hours", remaining: 0.27), window("Week", remaining: 0.9)]),
            card("codex", [window("5 hours", remaining: 0.6)]),
        ]
        let fullest = UsageCards.fullestWindow(cards, runtime: nil)
        #expect(fullest?.runtimeName == L10n.Runtime.claude)
        #expect(fullest?.windowLabel == "5 hours")
        #expect(fullest?.usedPercent == 73)
    }

    @Test func scopesToTheRuntimeWhenItHasACard() {
        let cards = [
            card("claude", [window("5 hours", remaining: 0.1)]),
            card("codex", [window("Week", remaining: 0.8)]),
        ]
        let fullest = UsageCards.fullestWindow(cards, runtime: "codex")
        #expect(fullest?.runtimeName == L10n.Runtime.codex)
        #expect(fullest?.windowLabel == "Week")
        #expect(fullest?.usedPercent == 20)
    }

    @Test func fallsBackToAllCardsWhenTheRuntimeHasNoCard() {
        let cards = [card("claude", [window("5 hours", remaining: 0.5)])]
        let fullest = UsageCards.fullestWindow(cards, runtime: "grok")
        #expect(fullest?.runtimeName == L10n.Runtime.claude)
        #expect(fullest?.usedPercent == 50)
    }

    @Test func noWindowsMeansNoFullestWindow() {
        #expect(UsageCards.fullestWindow([], runtime: nil) == nil)
        #expect(UsageCards.fullestWindow([card("claude", [])], runtime: nil) == nil)
    }

    @Test func aTieKeepsTheFirstWindow() {
        let cards = [
            card("claude", [window("5 hours", remaining: 0.4)]),
            card("codex", [window("Week", remaining: 0.4)]),
        ]
        #expect(UsageCards.fullestWindow(cards, runtime: nil)?.windowLabel == "5 hours")
    }

    @Test func aWindowWithANonFiniteRemainderIsSkipped() {
        let cards = [card("claude", [window("5 hours", remaining: .nan), window("Week", remaining: 0.75)])]
        let fullest = UsageCards.fullestWindow(cards, runtime: nil)
        #expect(fullest?.windowLabel == "Week")
        #expect(fullest?.usedPercent == 25)
    }

    @Test func usedPercentRoundsToTheNearestWholePercent() {
        let fullest = FullestWindow(runtimeName: "Claude Code", windowLabel: "5 hours", used: 0.7349)
        #expect(fullest.usedPercent == 73)
    }

    @Test func levelBoundariesAreUnder70CloseTo90Over() {
        #expect(UsageLevel(usedPercent: 0) == .ok)
        #expect(UsageLevel(usedPercent: 69) == .ok)
        #expect(UsageLevel(usedPercent: 70) == .close)
        #expect(UsageLevel(usedPercent: 90) == .close)
        #expect(UsageLevel(usedPercent: 91) == .over)
        #expect(UsageLevel(usedPercent: 100) == .over)
    }

    @Test func helpNamesTheRuntimeAndTheWindow() {
        let text = L10n.Usage.fullestHelp(percent: "73%", runtime: L10n.Runtime.claude, window: "5 hours")
        #expect(text.contains("73%"))
        #expect(text.contains(L10n.Runtime.claude))
        #expect(text.contains("5 hours"))
    }
}
