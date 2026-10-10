import BanditoKit
import BanditoL10n
import Foundation

// Pure rules of the Backups section: the reason of a copy, its date labels, and whether the section is shown.
// Calendar, locale and the reference time are parameters, so the tests fix them.

/// Why a copy was made, as the daemon names it in the file name (docs/ARCHITECTURE.md#backups).
enum BackupReason: Equatable {
    case start, upgrade, daily, manual, beforeRestore
    /// The database a restore set aside, whole (`replaced-*`), or a damaged one (`broken-*`). The daemon never
    /// deletes these; the list marks them as "saved before a restore".
    case replaced, broken
    /// A `-wal` or `-shm` of a set-aside database whose file is not there (a move that stopped in the middle). Kept
    /// in view, cannot be restored.
    case incomplete
    /// A reason this app does not know (a newer daemon): shown as a plain copy.
    case other

    init(raw: String) {
        switch raw {
        case "start": self = .start
        case "upgrade": self = .upgrade
        case "daily": self = .daily
        case "manual": self = .manual
        case "before-restore": self = .beforeRestore
        case "replaced": self = .replaced
        case "broken": self = .broken
        case "incomplete": self = .incomplete
        default: self = .other
        }
    }

    /// A database a restore set aside, not a copy the daemon made on its own schedule.
    var isSavedBeforeRestore: Bool { self == .replaced || self == .broken || self == .incomplete }

    /// Whether a copy of this kind can be restored: an incomplete group has no database file.
    var canRestore: Bool { self != .incomplete }

    /// The reason in words, as the list shows it.
    var title: String {
        switch self {
        case .start: L10n.Backups.Reason.start
        case .upgrade: L10n.Backups.Reason.upgrade
        case .daily: L10n.Backups.Reason.daily
        case .manual: L10n.Backups.Reason.manual
        case .beforeRestore: L10n.Backups.Reason.beforeRestore
        case .replaced: L10n.Backups.Reason.replaced
        case .broken: L10n.Backups.Reason.broken
        case .incomplete: L10n.Backups.Reason.incomplete
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

/// The time in a copy's name, `bandito-<YYYYMMDD-HHMMSS>-<reason>.db`, or in the name of a set-aside database,
/// `replaced-<YYYYMMDD-HHMMSS>.db` / `broken-<...>.db`. The daemon writes it in UTC.
enum BackupName {
    static func createdAt(_ name: String) -> Date? {
        let stampLength = 15
        guard let prefix = ["bandito-", "replaced-", "broken-"].first(where: { name.hasPrefix($0) }),
              let start = name.index(name.startIndex, offsetBy: prefix.count, limitedBy: name.endIndex),
              let end = name.index(start, offsetBy: stampLength, limitedBy: name.endIndex)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(name[start..<end]))
    }
}

/// What the restore the person asked for came to, as the app shows it once the server is back.
enum RestoreOutcome: Equatable {
    /// The database was replaced with the copy from `copyDate`.
    case restored(copyDate: Date)
    /// The daemon could not restore; `error` is its one-sentence reason.
    case failed(String)
    /// The server came back, but its record does not say what happened to this request.
    case unknown

    /// `record` is the daemon's last restore now. When the daemon returned an operation id for the request
    /// (`requestID`), only a record with that same id counts: an older result for the same copy is not taken for
    /// this one. A daemon without ids is judged by the old rule: the record must name the requested copy and differ
    /// from `before`, the one it reported before the request. Success is read from `ok`, not from the start time.
    static func from(
        requested name: String,
        requestID: String? = nil,
        record: LastRestore?,
        before: LastRestore?
    ) -> RestoreOutcome {
        guard let record, record.name == name else { return .unknown }
        if let requestID, !requestID.isEmpty {
            guard record.id == requestID else { return .unknown }
        } else if record == before {
            return .unknown
        }
        if !record.ok {
            return .failed(record.error ?? "")
        }
        guard let date = BackupName.createdAt(name) else { return .unknown }
        return .restored(copyDate: date)
    }
}

extension ServerSection {
    /// The sections the sidebar shows. Backups appears only when the server has the `backups` feature.
    static func visible(supportsBackups: Bool) -> [ServerSection] {
        allCases.filter { $0 != .backups || supportsBackups }
    }
}
