import BanditoL10n
import Foundation

/// Text for when a limit resets. Pure functions, so the usage popover and the tests share them.
public enum Countdown {
    /// "in 2 h 14 min", "in 41 min", "less than a minute", "in 5 d 20 h".
    /// With `exhausted`, a clock with seconds for a limit that is used up: "again in 5:48:12".
    public static func text(to reset: Date, now: Date, exhausted: Bool = false) -> String {
        let remaining = reset.timeIntervalSince(now)
        if exhausted {
            return L10n.Countdown.exhausted(time: clock(seconds: remaining))
        }
        let total = Int(remaining.rounded(.down))
        if total < 60 {
            return L10n.Countdown.lessThanMinute
        }
        let minutes = total / 60
        if minutes < 60 {
            return L10n.Countdown.minutes(count: minutes)
        }
        let hours = minutes / 60
        if hours < 24 {
            return L10n.Countdown.hoursMinutes(hours: String(hours), minutes: String(minutes % 60))
        }
        return L10n.Countdown.daysHours(days: String(hours / 24), hours: String(hours % 24))
    }

    /// When the limit resets: the time alone if it is today ("at 20:59"), otherwise the date and time.
    public static func resetText(
        to reset: Date, now: Date, calendar: Calendar = .current, timeZone: TimeZone = .current,
        locale: Locale = L10n.locale
    ) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        if calendar.isDate(reset, inSameDayAs: now) {
            return L10n.Usage.resetToday(time: reset.formatted(style.hour().minute()))
        }
        return reset.formatted(style.day().month(.abbreviated).hour().minute())
    }

    /// `h:mm:ss`, with the hours unpadded. Negative values read as zero.
    public static func clock(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return "\(hours):\(pad(minutes)):\(pad(secs))"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
