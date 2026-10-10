import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

/// The Backups section's rules: the reason of a copy in words, the date labels, and when the section is shown.
/// The calendar and the locale are fixed here (UTC, POSIX), so the labels do not depend on the machine.
@Suite struct BackupsLogicTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let locale = Locale(identifier: "en_US_POSIX")

    /// 2027-01-15 12:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_800_014_400)

    private func at(day: Int, hour: Int, minute: Int) -> Date {
        var parts = DateComponents()
        parts.year = 2027
        parts.month = 1
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return Self.calendar.date(from: parts)!
    }

    /// The time as the labels print it, so the expected text is built the same way the app builds it.
    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Self.locale
        formatter.calendar = Self.calendar
        formatter.timeZone = Self.calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    @Test func everyDaemonReasonHasItsOwnWord() {
        #expect(BackupReason(raw: "start") == .start)
        #expect(BackupReason(raw: "upgrade") == .upgrade)
        #expect(BackupReason(raw: "daily") == .daily)
        #expect(BackupReason(raw: "manual") == .manual)
        #expect(BackupReason(raw: "before-restore") == .beforeRestore)
    }

    @Test func aReasonFromANewerDaemonIsAPlainCopy() {
        #expect(BackupReason(raw: "weekly") == .other)
        #expect(BackupReason(raw: "") == .other)
        #expect(BackupReason(raw: "Start") == .other)
        #expect(BackupReason.other.title == L10n.Backups.Reason.other)
        #expect(BackupReason.beforeRestore.title == L10n.Backups.Reason.beforeRestore)
    }

    @Test func aCopyFromToday_saysTodayAndTheTime() {
        let date = at(day: 15, hour: 3, minute: 12)
        let label = BackupDateLabel.short(date, now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(label == L10n.Backups.whenToday(time: timeText(date)))
    }

    @Test func aCopyFromYesterday_saysYesterdayAndTheTime() {
        let date = at(day: 14, hour: 23, minute: 50)
        let label = BackupDateLabel.short(date, now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(label == L10n.Backups.whenYesterday(time: timeText(date)))
    }

    @Test func aCopyFromTwoDaysAgo_showsTheDateAndTheTime() {
        let date = at(day: 13, hour: 9, minute: 5)
        let label = BackupDateLabel.short(date, now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(label == BackupDateLabel.absolute(date, calendar: Self.calendar, locale: Self.locale))
        #expect(label.contains("2027"))
    }

    @Test func midnightCountsAsADayChange() {
        // 00:10 today: the copy of 23:59 yesterday is yesterday, not today.
        let now = at(day: 15, hour: 0, minute: 10)
        let date = at(day: 14, hour: 23, minute: 59)
        let label = BackupDateLabel.short(date, now: now, calendar: Self.calendar, locale: Self.locale)
        #expect(label == L10n.Backups.whenYesterday(time: timeText(date)))
    }

    @Test func theConfirmationDateIsAbsolute() {
        let date = at(day: 14, hour: 8, minute: 0)
        let text = BackupDateLabel.absolute(date, calendar: Self.calendar, locale: Self.locale)
        #expect(text.contains("14"))
        #expect(text.contains("2027"))
        #expect(text.contains("08:00") || text.contains("8:00"))
    }

    @Test func backupsIsShownOnlyWhenTheServerHasTheFeature() {
        #expect(!ServerSection.visible(supportsBackups: false).contains(.backups))
        #expect(ServerSection.visible(supportsBackups: true).contains(.backups))
        // The other sections keep their order, with the journal last.
        let withoutBackups = ServerSection.visible(supportsBackups: false)
        #expect(withoutBackups.last == .journal)
        #expect(withoutBackups.count == 7)
        #expect(ServerSection.visible(supportsBackups: true).count == 8)
    }
}
