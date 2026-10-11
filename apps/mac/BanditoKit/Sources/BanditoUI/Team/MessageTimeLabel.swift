import BanditoDesign
import BanditoL10n
import Foundation
import SwiftUI

/// When a message was sent, as the row of actions shows it. Pure rules (the formatters are kept, see `TimeFormatters`),
/// so they are tested without a view.
///
/// "today, 22:14:37" and "yesterday, 09:03:12" for the last two days, "11 Oct., 22:14:37" in this year, and
/// "11 Oct 2025, 22:14:37" in an older one. The clock is 24-hour and always shows the seconds.
enum MessageTimeLabel {
    /// The short label of a message sent at `date`, read against `now`.
    static func text(date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = TimeFormatters.shared.string(from: date, format: .clock, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.Message.Time.today(time: time)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return L10n.Message.Time.yesterday(time: time)
        }
        var day = TimeFormatters.shared.string(from: date, format: .dayMonth, calendar: calendar, locale: locale)
        // The year is written as a plain number after the day and month ("11 окт. 2025"): the locale's own year
        // format adds words in some languages ("2025 г."), and the short label stays one shape everywhere.
        let year = calendar.component(.year, from: date)
        if year != calendar.component(.year, from: now) { day += " \(year)" }
        return L10n.Message.Time.dated(date: day, time: time)
    }

    /// The whole date with the weekday, and the time with the seconds: the tooltip of the label.
    static func fullText(date: Date, calendar: Calendar, locale: Locale) -> String {
        let day = TimeFormatters.shared.string(from: date, format: .weekdayDate, calendar: calendar, locale: locale)
        let time = TimeFormatters.shared.string(from: date, format: .clock, calendar: calendar, locale: locale)
        return L10n.Message.Time.dated(date: day, time: time)
    }
}

/// The formats `MessageTimeLabel` uses.
enum MessageTimeFormat: Hashable {
    /// 24-hour clock with seconds: `22:14:37`.
    case clock
    /// The day and the month in the locale's order: `11 Oct.`
    case dayMonth
    /// The weekday, the day, the month and the year, in the locale's words (the tooltip).
    case weekdayDate

    fileprivate var template: String? {
        switch self {
        case .clock: nil
        case .dayMonth: "d MMM"
        case .weekdayDate: "EEEE d MMMM yyyy"
        }
    }
}

/// A `DateFormatter` is costly to make and a row asks for one on every hover, so formatters are kept by their settings.
/// Shared by the thread, so the cache is read under a lock (the same pattern as `L10n.LocaleCache`).
final class TimeFormatters: @unchecked Sendable {
    static let shared = TimeFormatters()

    private let lock = NSLock()
    private var made: [String: DateFormatter] = [:]

    func string(from date: Date, format: MessageTimeFormat, calendar: Calendar, locale: Locale) -> String {
        let key = "\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(format)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = made[key] { return cached.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if let template = format.template {
            formatter.setLocalizedDateFormatFromTemplate(template)
        } else {
            formatter.dateFormat = "HH:mm:ss"
        }
        made[key] = formatter
        return formatter.string(from: date)
    }
}

/// The time a message was sent, at the far end of its row of actions (see `MessageContainer`). The row is drawn only on
/// hover, so this view is built for the one message under the pointer. It is `Equatable`: a re-render of that row does
/// not format the time again. It takes no space the row does not already have (the row is a fixed height).
struct MessageTimeStamp: View, Equatable {
    var date: Date

    var body: some View {
        let locale = L10n.locale
        let calendar = Calendar.current
        let full = MessageTimeLabel.fullText(date: date, calendar: calendar, locale: locale)
        Text(MessageTimeLabel.text(date: date, now: .now, calendar: calendar, locale: locale))
            .font(BanditoFont.mono(size: 11))
            .foregroundStyle(Color.Bandito.text3)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .help(full)
            .accessibilityLabel(full)
    }
}
