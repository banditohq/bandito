@testable import BanditoKit
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

    @Test func aCopyNameGivesItsTimeInUTC() {
        #expect(BackupName.createdAt("bandito-20270115-080000-start.db") == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(BackupName.createdAt("notes.txt") == nil)
        #expect(BackupName.createdAt("bandito-2027") == nil)
    }

    @Test func aRestoreWithNoNewRecordForThisCopyIsUnknown() {
        let name = "bandito-20270115-080000-start.db"
        let old = LastRestore(name: name, ok: true, error: nil, atMs: 1)
        // No record yet, or only the record the daemon had before the request.
        #expect(RestoreOutcome.from(requested: name, record: nil, before: nil) == .unknown)
        #expect(RestoreOutcome.from(requested: name, record: old, before: old) == .unknown)
        // A record of another copy does not answer this request.
        let other = LastRestore(name: "bandito-20270114-080000-daily.db", ok: true, error: nil, atMs: 3)
        #expect(RestoreOutcome.from(requested: name, record: other, before: nil) == .unknown)
    }

    @Test func aRestoreIsReadFromItsOkFlag() {
        let name = "bandito-20270115-080000-start.db"
        let old = LastRestore(name: name, ok: true, error: nil, atMs: 1)
        let done = LastRestore(name: name, ok: true, error: nil, atMs: 2)
        #expect(RestoreOutcome.from(requested: name, record: done, before: old)
            == .restored(copyDate: Date(timeIntervalSince1970: 1_800_000_000)))
        let failed = LastRestore(name: name, ok: false, error: "the restored database does not open", atMs: 3)
        #expect(RestoreOutcome.from(requested: name, record: failed, before: old)
            == .failed("the restored database does not open"))
    }

    @Test func withAnOperationIdOnlyTheRecordWithThatIdCounts() {
        let name = "bandito-20270115-080000-start.db"
        // An earlier successful restore of the very same copy must not pass for this one.
        let older = LastRestore(name: name, ok: true, error: nil, atMs: 1, id: "op-old")
        let mine = LastRestore(name: name, ok: false, error: "no way back", atMs: 2, id: "op-new")
        #expect(RestoreOutcome.from(requested: name, requestID: "op-new", record: older, before: nil) == .unknown)
        // Even when the record differs from what the app saw before, a different id is not this request.
        #expect(RestoreOutcome.from(requested: name, requestID: "op-new", record: older, before: mine) == .unknown)
        #expect(RestoreOutcome.from(requested: name, requestID: "op-new", record: mine, before: older)
            == .failed("no way back"))
        let done = LastRestore(name: name, ok: true, error: nil, atMs: 3, id: "op-new")
        #expect(RestoreOutcome.from(requested: name, requestID: "op-new", record: done, before: older)
            == .restored(copyDate: Date(timeIntervalSince1970: 1_800_000_000)))
        // A record without an id (an older daemon) is not accepted for a request that has one.
        let noID = LastRestore(name: name, ok: true, error: nil, atMs: 3)
        #expect(RestoreOutcome.from(requested: name, requestID: "op-new", record: noID, before: nil) == .unknown)
    }

    @Test func withoutAnIdTheOldRuleStillApplies() {
        let name = "bandito-20270115-080000-start.db"
        let record = LastRestore(name: name, ok: true, error: nil, atMs: 2)
        #expect(RestoreOutcome.from(requested: name, requestID: nil, record: record, before: record) == .unknown)
        #expect(RestoreOutcome.from(requested: name, requestID: "", record: record, before: record) == .unknown)
        #expect(RestoreOutcome.from(requested: name, requestID: nil, record: record, before: nil)
            == .restored(copyDate: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func aSetAsideDatabaseIsMarkedAsSavedBeforeARestore() {
        #expect(BackupReason(raw: "replaced") == .replaced)
        #expect(BackupReason(raw: "broken") == .broken)
        #expect(BackupReason.replaced.isSavedBeforeRestore)
        #expect(BackupReason.broken.isSavedBeforeRestore)
        #expect(!BackupReason.beforeRestore.isSavedBeforeRestore)
        #expect(!BackupReason.other.isSavedBeforeRestore)
        #expect(BackupReason.replaced.title == L10n.Backups.Reason.replaced)
        #expect(BackupReason.broken.title == L10n.Backups.Reason.broken)
        #expect(BackupReason.replaced.title != BackupReason.broken.title)
    }

    @Test func aSetAsideNameGivesItsTime() {
        #expect(BackupName.createdAt("replaced-20270115-080000.db") == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(BackupName.createdAt("broken-20270115-080000-2.db") == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(BackupName.createdAt("replaced-") == nil)
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
