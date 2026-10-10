import BanditoL10n
import Foundation

// Pure rules of the Backups section: the reason of a copy, its date labels, and whether the section is shown.
// Calendar, locale and the reference time are parameters, so the tests fix them.

/// Why a copy was made, as the daemon names it in the file name (docs/ARCHITECTURE.md#backups).
enum BackupReason: Equatable {
    case start, upgrade, daily, manual, beforeRestore
    /// A reason this app does not know (a newer daemon): shown as a plain copy.
    case other

    init(raw: String) {
        switch raw {
        case "start": self = .start
        case "upgrade": self = .upgrade
        case "daily": self = .daily
        case "manual": self = .manual
        case "before-restore": self = .beforeRestore
        default: self = .other
        }
    }

    /// The reason in words, as the list shows it.
    var title: String {
        switch self {
        case .start: L10n.Backups.Reason.start
        case .upgrade: L10n.Backups.Reason.upgrade
        case .daily: L10n.Backups.Reason.daily
        case .manual: L10n.Backups.Reason.manual
        case .beforeRestore: L10n.Backups.Reason.beforeRestore
        case .other: L10n.Backups.Reason.other
        }
    }
}

/// The dates of the copies: today and yesterday in words, other days by their date.
enum BackupDateLabel {
    /// "Today, 03:12", "Yesterday, 03:12", or, for an older copy, the date and the time (`absolute`).
    static func short(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = formatter(calendar, locale, dateStyle: .none).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.Backups.whenToday(time: time)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return L10n.Backups.whenYesterday(time: time)
        }
        return absolute(date, calendar: calendar, locale: locale)
    }

    /// The date and the time in full, such as "15 Jan 2027, 08:00". Used where the day in words would read oddly.
    static func absolute(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        formatter(calendar, locale, dateStyle: .medium).string(from: date)
    }

    /// Time of day with the date style given; the time is always short ("03:12" in 24-hour locales).
    private static func formatter(_ calendar: Calendar, _ locale: Locale, dateStyle: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = .short
        return formatter
    }
}

extension ServerSection {
    /// The sections the sidebar shows. Backups appears only when the server has the `backups` feature.
    static func visible(supportsBackups: Bool) -> [ServerSection] {
        allCases.filter { $0 != .backups || supportsBackups }
    }
}
