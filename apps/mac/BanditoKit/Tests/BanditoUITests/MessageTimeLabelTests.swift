import Foundation
import Testing

@testable import BanditoL10n
@testable import BanditoUI

/// The time under a message: the word for the last two days, the date for the older ones, the clock with seconds.
/// The calendar is Vladivostok (the owner's zone), so the midnight cases are the owner's midnight.
@Suite struct MessageTimeLabelTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Vladivostok")!
        return calendar
    }()

    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: parts)!
    }

    /// The label in one app language (task-local, so other suites running in parallel keep the system language).
    private func label(_ date: Date, now: Date, language: String) -> String {
        L10n.withLanguageForTests(language) {
            MessageTimeLabel.text(
                date: date, now: now, calendar: Self.calendar, locale: Locale(identifier: language == "ru" ? "ru_RU" : "en_US"))
        }
    }

    private func fullText(_ date: Date, language: String) -> String {
        L10n.withLanguageForTests(language) {
            MessageTimeLabel.fullText(
                date: date, calendar: Self.calendar, locale: Locale(identifier: language == "ru" ? "ru_RU" : "en_US"))
        }
    }

    @Test func aMessageFromToday() {
        let now = Self.at(2026, 10, 12, 15, 0, 0)
        #expect(label(Self.at(2026, 10, 12, 14, 22, 5), now: now, language: "ru") == "сегодня, 14:22:05")
        #expect(label(Self.at(2026, 10, 12, 14, 22, 5), now: now, language: "en") == "today, 14:22:05")
    }

    @Test func aMessageFromYesterday() {
        let now = Self.at(2026, 10, 12, 15, 0, 0)
        #expect(label(Self.at(2026, 10, 11, 9, 3, 12), now: now, language: "ru") == "вчера, 09:03:12")
        #expect(label(Self.at(2026, 10, 11, 9, 3, 12), now: now, language: "en") == "yesterday, 09:03:12")
    }

    @Test func anOlderMessageOfThisYearShowsTheDayAndMonthOnly() {
        let now = Self.at(2026, 10, 12, 15, 0, 0)
        #expect(label(Self.at(2026, 10, 3, 22, 14, 37), now: now, language: "ru") == "3 окт., 22:14:37")
    }

    @Test func aMessageFromLastYearShowsTheYearToo() {
        let now = Self.at(2026, 10, 12, 15, 0, 0)
        #expect(label(Self.at(2025, 10, 11, 22, 14, 37), now: now, language: "ru") == "11 окт. 2025, 22:14:37")
    }

    @Test func midnightSplitsTodayFromYesterdayAndTheDayBefore() {
        let now = Self.at(2026, 10, 12, 0, 0, 0)
        #expect(label(Self.at(2026, 10, 12, 0, 0, 0), now: now, language: "ru") == "сегодня, 00:00:00")
        #expect(label(Self.at(2026, 10, 11, 23, 59, 59), now: now, language: "ru") == "вчера, 23:59:59")
        #expect(label(Self.at(2026, 10, 10, 23, 59, 59), now: now, language: "ru") == "10 окт., 23:59:59")
    }

    @Test func yesterdayAcrossNewYearIsStillYesterday() {
        let now = Self.at(2026, 1, 1, 0, 10, 0)
        #expect(label(Self.at(2025, 12, 31, 23, 50, 0), now: now, language: "ru") == "вчера, 23:50:00")
        #expect(label(Self.at(2025, 12, 30, 12, 0, 0), now: now, language: "ru") == "30 дек. 2025, 12:00:00")
    }

    @Test func theClockIsTwentyFourHourWithSeconds() {
        let now = Self.at(2026, 10, 12, 23, 0, 0)
        #expect(label(Self.at(2026, 10, 12, 0, 30, 5), now: now, language: "en") == "today, 00:30:05")
        #expect(label(Self.at(2026, 10, 12, 21, 5, 9), now: now, language: "en") == "today, 21:05:09")
        #expect(!label(Self.at(2026, 10, 12, 0, 30, 5), now: now, language: "en").contains("AM"))
    }

    @Test func theTooltipHasTheWeekdayTheDateTheYearAndTheSeconds() {
        let ru = fullText(Self.at(2026, 10, 11, 22, 14, 37), language: "ru")
        #expect(ru.contains("воскресенье"))
        #expect(ru.contains("11 октября 2026"))
        #expect(ru.hasSuffix("22:14:37"))

        let en = fullText(Self.at(2026, 10, 11, 22, 14, 37), language: "en")
        #expect(en.contains("Sunday"))
        #expect(en.contains("October 11, 2026"))
        #expect(en.hasSuffix("22:14:37"))
    }

    @Test func repeatedCallsGiveTheSameTextFromTheKeptFormatters() {
        let now = Self.at(2026, 10, 12, 15, 0, 0)
        let date = Self.at(2026, 10, 3, 22, 14, 37)
        let first = label(date, now: now, language: "ru")
        let second = label(date, now: now, language: "ru")
        #expect(first == second)
        #expect(first == "3 окт., 22:14:37")
    }
}
