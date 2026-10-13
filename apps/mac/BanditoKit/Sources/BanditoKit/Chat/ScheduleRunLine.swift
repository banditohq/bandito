import BanditoL10n
import Foundation

// A scheduled run and a quiet turn are lines of the thread, not messages. The words of those lines.

/// What the lines say. Pure, for the tests.
public enum ScheduleRunLine {
    /// A schedule's name is cut to this many characters on its line (the line stays one line in a narrow chat).
    public static let nameLimit = 32

    /// "Scheduled run · Morning digest · today, 20:45" (the name left out when the schedule has none).
    public static func text(_ run: ScheduleRun, now: Date = Date(), calendar: Calendar = .current) -> String {
        head(run) + separator + time(run.firedAt, now: now, calendar: calendar)
    }

    /// "Scheduled run · Morning digest": the part of the line that gives way in a narrow chat (the time never does).
    public static func head(_ run: ScheduleRun) -> String {
        var parts = [L10n.Thread.scheduledRun]
        let name = run.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { parts.append(name.count > nameLimit ? String(name.prefix(nameLimit - 1)) + "…" : name) }
        return parts.joined(separator: separator)
    }

    public static let separator = " · "

    /// "today, 20:45", "yesterday, 08:00", or the date and the time.
    public static func time(_ ms: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let clock = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return L10n.Thread.ScheduleRun.today(time: clock) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.Thread.ScheduleRun.yesterday(time: clock)
        }
        return L10n.Thread.ScheduleRun.date(date: date.formatted(.dateTime.day().month(.abbreviated)), time: clock)
    }

    /// A quiet turn's reason is cut to this many characters on its line.
    public static let reasonLimit = 48

    /// "Nothing new", with the agent's reason after it when it gave one (cut: the line stays one line).
    public static func quiet(reason: String?) -> String {
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reason.isEmpty else { return L10n.Thread.QuietTurn.title }
        let cut = reason.count > reasonLimit ? String(reason.prefix(reasonLimit - 1)) + "…" : reason
        return L10n.Thread.QuietTurn.title + separator + cut
    }

    /// The keys of the two folds in `ThreadDisclosure`.
    public static func runKey(_ id: String) -> String { "schedule-\(id)" }
    public static func quietKey(_ id: String) -> String { "quiet-\(id)" }
}
