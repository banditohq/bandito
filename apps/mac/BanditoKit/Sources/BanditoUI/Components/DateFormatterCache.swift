import Foundation

/// Date formatters kept for reuse. Making a `DateFormatter` costs more than formatting with it, and a list that shows a
/// time on every row (the call journal, the backups) made one per row at every redraw. A formatter is keyed by everything
/// that decides what it prints; one is never shared between threads at the same moment (a lock holds the whole call).
final class DateFormatterCache: @unchecked Sendable {
    static let shared = DateFormatterCache()

    private struct Key: Hashable {
        let locale: String
        let calendar: Calendar.Identifier
        let timeZone: String
        let dateStyle: UInt
        let timeStyle: UInt
    }

    private let lock = NSLock()
    private var formatters: [Key: DateFormatter] = [:]

    func string(
        from date: Date, calendar: Calendar, locale: Locale, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style
    ) -> String {
        let key = Key(
            locale: locale.identifier, calendar: calendar.identifier, timeZone: calendar.timeZone.identifier,
            dateStyle: dateStyle.rawValue, timeStyle: timeStyle.rawValue)
        return lock.withLock {
            let formatter: DateFormatter
            if let known = formatters[key] {
                formatter = known
            } else {
                formatter = DateFormatter()
                formatter.locale = locale
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.dateStyle = dateStyle
                formatter.timeStyle = timeStyle
                // Few combinations exist in practice; a runaway key set (a test) is cut rather than kept.
                if formatters.count >= 32 { formatters.removeAll() }
                formatters[key] = formatter
            }
            return formatter.string(from: date)
        }
    }
}
