import BanditoL10n
import Foundation

/// A cron expression of a template in the person's words: "Weekdays at 8:00 AM". An expression it does not read
/// (steps, ranges of hours, a day of the month) is left as it is, in monospace by the view.
public enum BotScheduleWords {
    enum Days: Equatable {
        case every
        case weekdays
        /// Cron weekday numbers, 0 is Sunday.
        case list([Int])
    }

    struct Reading: Equatable {
        var days: Days
        /// Minutes since midnight, in the order of the expression.
        var times: [Int]
    }

    /// The days and the times of `cron`, or nil when it is not of the plain kind the templates use: one minute, a list
    /// of hours, any day of the month and of the year, and every day, the weekdays or a list of weekdays.
    static func reading(_ cron: String) -> Reading? {
        let fields = cron.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5, fields[2] == "*", fields[3] == "*",
            let minute = Int(fields[0]), (0...59).contains(minute)
        else { return nil }
        let hours = fields[1].split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
        guard !hours.isEmpty, hours.allSatisfy({ $0.map { (0...23).contains($0) } ?? false }) else { return nil }
        let times = hours.compactMap { $0 }.map { $0 * 60 + minute }
        let days: Days
        switch fields[4] {
        case "*": days = .every
        case "1-5": days = .weekdays
        default:
            let parts = fields[4].split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0.map { (0...7).contains($0) } ?? false }) else { return nil }
            let numbers = parts.compactMap { $0 }.map { $0 == 7 ? 0 : $0 }
            days = .list(Array(Set(numbers)).sorted())
        }
        return Reading(days: days, times: times)
    }

    /// The words for `cron` in `languageCode`, or nil when the expression is not read.
    public static func words(cron: String, languageCode: String) -> String? {
        guard let reading = reading(cron) else { return nil }
        let locale = Locale(identifier: languageCode)
        let clock = DateFormatter()
        clock.locale = locale
        clock.timeZone = TimeZone(identifier: "UTC")
        clock.dateStyle = .none
        clock.timeStyle = .short
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let times = reading.times.compactMap { total -> String? in
            var parts = DateComponents(year: 2024, month: 1, day: 1, hour: total / 60, minute: total % 60)
            parts.timeZone = calendar.timeZone
            return calendar.date(from: parts).map { clock.string(from: $0) }
        }.joined(separator: ", ")
        switch reading.days {
        case .every:
            return L10n.Market.Bot.When.daily(time: times)
        case .weekdays:
            return L10n.Market.Bot.When.weekdays(time: times)
        case .list(let numbers):
            let names = DateFormatter()
            names.locale = locale
            let symbols = names.shortWeekdaySymbols ?? []
            let list = numbers.compactMap { symbols.indices.contains($0) ? symbols[$0] : nil }.joined(separator: ", ")
            return L10n.Market.Bot.When.days(days: list, time: times)
        }
    }
}
