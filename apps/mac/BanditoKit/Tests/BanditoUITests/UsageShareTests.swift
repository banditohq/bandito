import Testing

@testable import BanditoUI

/// The share used of a window, read from `remaining`, and the fullest window built on it. Values outside 0...1
/// (the card's `remaining` should never be one, but a bad input must not leave the bar's ends) are clamped.
@Suite struct UsageShareTests {
    private func line(_ remaining: Double) -> UsageWindowLine {
        UsageWindowLine(id: "w", label: "5 hours", remaining: remaining, resetsAt: nil, note: nil)
    }

    private func card(_ remaining: Double) -> UsageCard {
        UsageCard(runtime: "claude", name: "Claude", plan: nil, color: .peach, who: nil, windows: [line(remaining)])
    }

    @Test func usedIsTheShareNotLeft() {
        #expect(line(0.27).used == 1 - 0.27)
        #expect(line(1).used == 0)
        #expect(line(0).used == 1)
    }

    @Test func remainingBelowZeroCountsAsFullyUsed() {
        #expect(line(-0.5).used == 1)
        #expect(UsageCards.fullestWindow([card(-0.5)], runtime: nil)?.usedPercent == 100)
    }

    @Test func remainingAboveOneCountsAsNothingUsed() {
        #expect(line(1.7).used == 0)
        #expect(UsageCards.fullestWindow([card(1.7)], runtime: nil)?.usedPercent == 0)
    }

    @Test func nanCountsAsNothingUsed() {
        #expect(line(.nan).used == 0)
        #expect(UsageCards.fullestWindow([card(.nan)], runtime: nil)?.usedPercent == 0)
    }

    @Test func aClampedWindowStillLosesToAFullerOne() {
        let cards = [card(1.7), card(0.4)]
        #expect(UsageCards.fullestWindow(cards, runtime: nil)?.usedPercent == 60)
    }
}
