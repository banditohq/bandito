@testable import BanditoKit
import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

/// The limit windows of a runtime: their names, their order, their reset times.
@Suite struct UsageWindowsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ name: String, _ utilization: Double = 0.2, resetsIn seconds: Int64? = nil) -> LimitWindow {
        LimitWindow(name: name, utilization: utilization, resetsAt: seconds.map { Int64(now.timeIntervalSince1970) + $0 })
    }

    @Test func knownWindowNamesGetTheirLengthInMinutes() {
        #expect(UsageCards.windowMinutes("five_hour") == 300)
        #expect(UsageCards.windowMinutes("5h") == 300)
        #expect(UsageCards.windowMinutes("one_day") == 1440)
        #expect(UsageCards.windowMinutes("daily") == 1440)
        #expect(UsageCards.windowMinutes("1d") == 1440)
        #expect(UsageCards.windowMinutes("seven_day") == 10080)
        #expect(UsageCards.windowMinutes("weekly") == 10080)
        #expect(UsageCards.windowMinutes("seven_day_opus") == 10080)
        #expect(UsageCards.windowMinutes("seven_day_sonnet") == 10080)
        #expect(UsageCards.windowMinutes("90m") == 90)
        #expect(UsageCards.windowMinutes("1440m") == 1440)
        #expect(UsageCards.windowMinutes("weird_name") == nil)
        #expect(UsageCards.windowMinutes("m") == nil)
        #expect(UsageCards.windowMinutes("0m") == nil)
    }

    @Test func labelsReadAsPeopleSayThem() {
        #expect(UsageCards.windowLabel("five_hour") == L10n.Inspector.Window.fiveHour)
        #expect(UsageCards.windowLabel("5h") == L10n.Inspector.Window.fiveHour)
        #expect(UsageCards.windowLabel("seven_day") == L10n.Inspector.Window.sevenDay)
        #expect(UsageCards.windowLabel("weekly") == L10n.Inspector.Window.sevenDay)
        #expect(UsageCards.windowLabel("one_day") == L10n.Usage.Window.day)
        #expect(UsageCards.windowLabel("1440m") == L10n.Usage.Window.day)
        #expect(UsageCards.windowLabel("seven_day_opus") == L10n.Usage.Window.weekModel(model: "Opus"))
        #expect(UsageCards.windowLabel("seven_day_sonnet") == L10n.Usage.Window.weekModel(model: "Sonnet"))
        #expect(UsageCards.windowLabel("4320m") == L10n.Usage.Window.days(count: 3))
        #expect(UsageCards.windowLabel("720m") == L10n.Usage.Window.hours(count: 12))
        #expect(UsageCards.windowLabel("60m") == L10n.Usage.Window.hours(count: 1))
        #expect(UsageCards.windowLabel("90m") == L10n.Usage.Window.minutes(minutes: "90"))
        #expect(UsageCards.windowLabel("weird_name") == "Weird name")
    }

    @Test func windowsSortShortestFirstAndUnknownLast() {
        let names = ["weird_name", "seven_day", "90m", "five_hour", "seven_day_opus", "1440m", "4320m"]
        let sorted = UsageCards.sortedWindows(names.map { window($0) }).map(\.name)
        // Equal lengths keep the order the daemon sent them in.
        #expect(sorted == ["90m", "five_hour", "1440m", "4320m", "seven_day", "seven_day_opus", "weird_name"])
    }

    @Test func cardsKeepTheWindowsOfAFiveHourOnlyPlan() {
        let entry = UsageEntry(runtime: "codex", windows: [window("five_hour", 0.1, resetsIn: 3_600)], updatedAt: 0)
        let cards = UsageCards.cards(from: [entry], agentCounts: [:], now: now)
        #expect(cards.first?.windows.map(\.label) == [L10n.Inspector.Window.fiveHour])
    }

    /// Reproduces the old bug in the new-agent card: a window that had already reset (its stored reset time in the
    /// past) read as "resets in less than a minute", because the smallest reset of all windows was taken. A reset in
    /// the past is not a countdown at all.
    @Test func staleResetTimeDoesNotBecomeACountdown() {
        let entry = UsageEntry(
            runtime: "claude",
            windows: [window("five_hour", 1, resetsIn: -3_600), window("seven_day", 0.3, resetsIn: 9_000)],
            updatedAt: 0)
        let cards = UsageCards.cards(from: [entry], agentCounts: [:], now: now)
        // The stale five-hour window is not used up any more: nothing counts down to it.
        #expect(UsageCards.exhaustedReset(cards.first?.windows ?? [], now: now) == nil)
        #expect(cards.first?.windows.first?.resetsAt == nil)
    }

    /// A week at 100% (5 days) and a five-hour window at 20% (1 hour): the runtime is back when the week resets.
    @Test func exhaustedResetIsTheLatestUsedUpWindowAhead() {
        let entry = UsageEntry(
            runtime: "claude",
            windows: [window("five_hour", 0.2, resetsIn: 3_600), window("seven_day", 1, resetsIn: 5 * 86_400)],
            updatedAt: 0)
        let cards = UsageCards.cards(from: [entry], agentCounts: [:], now: now)
        let until = UsageCards.exhaustedReset(cards.first?.windows ?? [], now: now)
        #expect(until == now.addingTimeInterval(5 * 86_400))
        #expect(Countdown.text(to: until ?? now, now: now) == L10n.Countdown.days(count: 5))
    }

    @Test func exhaustedResetIsNilWhenNothingIsUsedUp() {
        let entry = UsageEntry(runtime: "claude", windows: [window("five_hour", 0.5, resetsIn: 600)], updatedAt: 0)
        let cards = UsageCards.cards(from: [entry], agentCounts: [:], now: now)
        #expect(UsageCards.exhaustedReset(cards.first?.windows ?? [], now: now) == nil)
    }

    @Test func aWindowPastItsResetIsUnusedAndHasNoCountdown() {
        let entry = UsageEntry(runtime: "claude", windows: [window("five_hour", 0.9, resetsIn: -60)], updatedAt: 0)
        let line = UsageCards.cards(from: [entry], agentCounts: [:], now: now).first?.windows.first
        #expect(line?.used == 0)
        #expect(line?.resetsAt == nil)
        #expect(!(line?.exhausted ?? true))
    }

    @Test func aWindowResetsAtItsTimeWhenItIsStillAhead() {
        let entry = UsageEntry(runtime: "claude", windows: [window("five_hour", 0.25, resetsIn: 600)], updatedAt: 0)
        let line = UsageCards.cards(from: [entry], agentCounts: [:], now: now).first?.windows.first
        #expect(abs((line?.used ?? 0) - 0.25) < 0.0001)
        #expect(line?.resetsAt == now.addingTimeInterval(600))
    }
}
