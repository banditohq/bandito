import Foundation

/// The rule the daemon checks on a schedule: the two runs that come after a moment must be at least five minutes
/// apart (docs/ARCHITECTURE.md#scheduler). The schedule form runs the same check on a custom expression before it is
/// sent, in the device's zone, so the owner sees the reason in the form. Standard five-field cron; an expression this
/// reader does not know (names, `L`, `#`, `?`) is left to the daemon.
public enum CronInterval {
    public static let minimumMinutes = 5

    /// The gap in minutes between the first two runs after `from`, or nil when the expression is not read or has fewer
    /// than two runs in the next year.
    public static func gapBetweenNextRuns(_ cron: String, after from: Date, calendar: Calendar = .current) -> Int? {
        let fields = cron.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5,
              let minutes = parse(fields[0], 0...59),
              let hours = parse(fields[1], 0...23),
              let days = parse(fields[2], 1...31),
              let months = parse(fields[3], 1...12),
              let weekdaysRaw = parse(fields[4], 0...7)
        else { return nil }
        let weekdays = Set(weekdaysRaw.map { $0 == 7 ? 0 : $0 })
        let dayRestricted = fields[2] != "*"
        let weekdayRestricted = fields[4] != "*"

        var day = calendar.startOfDay(for: from)
        var runs: [Date] = []
        for _ in 0..<400 {
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if let year = parts.year, let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday {
                let dayOfWeek = weekday - 1
                let dayMatches = dayRestricted && weekdayRestricted
                    ? days.contains(dayOfMonth) || weekdays.contains(dayOfWeek)
                    : days.contains(dayOfMonth) && weekdays.contains(dayOfWeek)
                if months.contains(month), dayMatches {
                    for hour in hours.sorted() {
                        for minute in minutes.sorted() {
                            let when = DateComponents(
                                year: year, month: month, day: dayOfMonth, hour: hour, minute: minute)
                            guard let date = calendar.date(from: when), date > from else { continue }
                            runs.append(date)
                            if runs.count == 2 {
                                return Int(runs[1].timeIntervalSince(runs[0]) / 60)
                            }
                        }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// True when the two runs after `from` are closer than the minimum.
    public static func tooOften(_ cron: String, after from: Date, calendar: Calendar = .current) -> Bool {
        guard let gap = gapBetweenNextRuns(cron, after: from, calendar: calendar) else { return false }
        return gap < minimumMinutes
    }

    /// One cron field as the set of values it names: `*`, `*/n`, `a`, `a-b`, `a-b/n`, `a/n`, and lists of them.
    static func parse(_ text: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var values = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let step: Int
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]), parsed > 0 else { return nil }
                step = parsed
            } else {
                step = 1
            }
            let base = pieces[0]
            let low: Int
            let high: Int
            if base == "*" {
                low = range.lowerBound
                high = range.upperBound
            } else if base.contains("-") {
                let ends = base.split(separator: "-", omittingEmptySubsequences: false)
                guard ends.count == 2, let a = Int(ends[0]), let b = Int(ends[1]) else { return nil }
                low = a
                high = b
            } else {
                guard let a = Int(base) else { return nil }
                low = a
                high = pieces.count == 2 ? range.upperBound : a
            }
            guard range.contains(low), range.contains(high), low <= high else { return nil }
            values.formUnion(stride(from: low, through: high, by: step))
        }
        return values.isEmpty ? nil : values
    }
}
