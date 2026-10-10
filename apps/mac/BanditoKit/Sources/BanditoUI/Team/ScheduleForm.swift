import Foundation

/// What the schedule editor collects, and the cron expression it makes. Pure: the sheet only binds to it.
/// `reading(cron:)` goes the other way, so a schedule opens in the editor as it was made. A cron the editor cannot
/// name stays as it is, under "Другое (cron)".
public struct ScheduleForm: Equatable, Sendable {
    /// How often: the choices of the first row of the editor.
    public enum Rhythm: Equatable, Sendable, CaseIterable {
        case every, daily, weekdays, days, custom
    }

    /// The interval of the "every" choice. Minutes are 5, 10, 15 or 30; hours are 1, 2, 3, 4, 6, 8 or 12.
    public enum Step: Equatable, Hashable, Sendable {
        case minutes(Int)
        case hours(Int)

        /// Every step, in the order the menu shows them.
        public static let all: [Step] = [
            .minutes(5), .minutes(10), .minutes(15), .minutes(30),
            .hours(1), .hours(2), .hours(3), .hours(4), .hours(6), .hours(8), .hours(12),
        ]

        /// The cron fields of the step: clock-aligned, so `every 1 hour` runs at the top of each hour.
        public var cron: String {
            switch self {
            case .minutes(let n): "*/\(n) * * * *"
            case .hours(1): "0 * * * *"
            case .hours(let n): "0 */\(n) * * *"
            }
        }
    }

    /// The longest title, in characters. The daemon refuses a longer one.
    public static let titleLimit = 80

    public var rhythm: Rhythm = .daily
    public var step: Step = .hours(1)
    public var hour = 9
    public var minute = 0
    /// Days as cron numbers: 0 is Sunday, 6 is Saturday. Used by `days`.
    public var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    /// The expression typed under "Другое (cron)".
    public var customCron = ""
    public var title = ""
    public var prompt = ""

    public init() {}

    /// The cron expression the editor saves, or nil while the form is not complete: no day picked, a time out of
    /// range, or a custom expression that does not have five fields.
    public var cron: String? {
        switch rhythm {
        case .every:
            return step.cron
        case .daily:
            return timeCron(days: "*")
        case .weekdays:
            return timeCron(days: "1-5")
        case .days:
            guard !weekdays.isEmpty else { return nil }
            if weekdays.count == 7 { return timeCron(days: "*") }
            return timeCron(days: weekdays.sorted().map(String.init).joined(separator: ","))
        case .custom:
            let text = Self.collapsed(customCron)
            return Self.fieldCount(text) == 5 ? text : nil
        }
    }

    /// The form can be saved: a valid cron, a prompt, and a title within the limit (an empty title is allowed).
    public var canSave: Bool {
        cron != nil && !Self.trimmed(prompt).isEmpty && Self.trimmed(title).count <= Self.titleLimit
    }

    /// A custom expression whose two runs after `now` are closer than five minutes. The daemon refuses it too; the form
    /// says so before the save. Other choices are never this often.
    public func tooOften(now: Date, calendar: Calendar = .current) -> Bool {
        guard rhythm == .custom, let cron else { return false }
        return CronInterval.tooOften(cron, after: now, calendar: calendar)
    }

    /// The title as the daemon takes it: trimmed, and nil when empty.
    public var titleOrNil: String? {
        let text = Self.trimmed(title)
        return text.isEmpty ? nil : text
    }

    /// Reads a cron expression back into the choices. Anything the choices cannot say becomes `custom`, with the
    /// expression kept as typed.
    public static func reading(cron: String) -> ScheduleForm {
        var form = ScheduleForm()
        let text = collapsed(cron)
        form.customCron = text
        form.rhythm = .custom
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return form }
        let minuteField = fields[0]
        let hourField = fields[1]
        let dom = fields[2]
        let month = fields[3]
        let dow = fields[4]
        guard dom == "*", month == "*" else { return form }

        if dow == "*" {
            if let step = stepReading(minute: minuteField, hour: hourField) {
                form.rhythm = .every
                form.step = step
                return form
            }
            if let time = clock(hour: hourField, minute: minuteField) {
                form.rhythm = .daily
                form.hour = time.hour
                form.minute = time.minute
            }
            return form
        }
        guard let time = clock(hour: hourField, minute: minuteField) else { return form }
        if dow == "1-5" {
            form.rhythm = .weekdays
            form.hour = time.hour
            form.minute = time.minute
            return form
        }
        let parts = dow.split(separator: ",")
        let days = parts.compactMap { Int($0) }
        if !days.isEmpty, days.count == parts.count, days.allSatisfy({ (0...6).contains($0) }) {
            form.rhythm = .days
            form.hour = time.hour
            form.minute = time.minute
            form.weekdays = Set(days)
        }
        return form
    }

    // MARK: - helpers

    private func timeCron(days: String) -> String? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return "\(minute) \(hour) * * \(days)"
    }

    /// The step that a minute and an hour field name, if the editor offers it.
    private static func stepReading(minute: String, hour: String) -> Step? {
        Step.all.first { $0.cron == "\(minute) \(hour) * * *" }
    }

    /// The hour and minute of two cron fields, when both are plain numbers in range.
    private static func clock(hour: String, minute: String) -> (hour: Int, minute: Int)? {
        guard let h = Int(hour), let m = Int(minute), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }

    private static func fieldCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: " ").count
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
