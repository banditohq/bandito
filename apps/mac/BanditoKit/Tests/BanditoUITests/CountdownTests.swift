import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

/// The expected strings come from `L10n`, so these tests hold in any app language.
@Suite struct CountdownTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func hoursAndMinutes() {
        let text = Countdown.text(to: now.addingTimeInterval(2 * 3600 + 14 * 60), now: now)
        #expect(text == L10n.Countdown.hoursMinutes(hours: "2", minutes: "14"))
    }

    @Test func lessThanAnHourShowsMinutesOnly() {
        let text = Countdown.text(to: now.addingTimeInterval(41 * 60), now: now)
        #expect(text == L10n.Countdown.minutes(count: 41))
    }

    @Test func lessThanAMinute() {
        #expect(Countdown.text(to: now.addingTimeInterval(30), now: now) == L10n.Countdown.lessThanMinute)
        // A reset time already in the past reads the same way until the limit is refreshed.
        #expect(Countdown.text(to: now.addingTimeInterval(-10), now: now) == L10n.Countdown.lessThanMinute)
    }

    @Test func daysAndHours() {
        let text = Countdown.text(to: now.addingTimeInterval(5 * 86_400 + 20 * 3600), now: now)
        #expect(text == L10n.Countdown.daysHours(days: "5", hours: "20"))
    }

    @Test func exhaustedShowsClockWithSeconds() {
        let text = Countdown.text(to: now.addingTimeInterval(5 * 3600 + 48 * 60 + 12), now: now, exhausted: true)
        #expect(text == L10n.Countdown.exhausted(time: "5:48:12"))
    }

    @Test func exhaustedUnderAnHourKeepsTheClockFormat() {
        let text = Countdown.text(to: now.addingTimeInterval(125), now: now, exhausted: true)
        #expect(text == L10n.Countdown.exhausted(time: "0:02:05"))
    }

    @Test func clockFormatPadsMinutesAndSeconds() {
        #expect(Countdown.clock(seconds: 3_661) == "1:01:01")
        #expect(Countdown.clock(seconds: 0) == "0:00:00")
        #expect(Countdown.clock(seconds: -5) == "0:00:00")
    }

    @Test func resetTodayShowsOnlyTheTime() {
        let utc = Self.utcCalendar
        let ru = Locale(identifier: "ru_RU")
        let reset = Self.date(2026, 10, 9, 20, 59)
        let morning = Self.date(2026, 10, 9, 9, 0)
        let text = Countdown.resetText(to: reset, now: morning, calendar: utc, timeZone: utc.timeZone, locale: ru)
        #expect(text == L10n.Usage.resetToday(time: "20:59"))
    }

    @Test func resetOnAnotherDayShowsDateAndTime() {
        let utc = Self.utcCalendar
        let ru = Locale(identifier: "ru_RU")
        let reset = Self.date(2026, 10, 15, 10, 59)
        let now = Self.date(2026, 10, 9, 9, 0)
        let text = Countdown.resetText(to: reset, now: now, calendar: utc, timeZone: utc.timeZone, locale: ru)
        #expect(text.contains("15"))
        #expect(text.contains("10:59"))
        #expect(text != L10n.Usage.resetToday(time: "10:59"))
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return utcCalendar.date(from: parts)!
    }
}
