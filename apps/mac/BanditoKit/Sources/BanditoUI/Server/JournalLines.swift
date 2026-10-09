import Foundation

/// One line of the daemon's log, split into its parts. A line of another shape (a continuation, a journald line)
/// keeps its text as the message and has no time, level or module.
public struct JournalLine: Equatable, Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case trace = "TRACE"
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    /// Local time, `16:00:45`. The daemon writes UTC; the journal shows the Mac's time.
    public var time: String?
    public var level: Level?
    /// The module that wrote the line, such as `bandito::rpc`. Only a word with `::` counts as a module.
    public var module: String?
    public var message: String

    /// A line is `<time> <LEVEL> <module>: <message>`, where the time and the module are optional.
    public init(_ line: String, timeZone: TimeZone = .current) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.wholeMatch(of: /(?:(\S+)\s+)?(TRACE|DEBUG|INFO|WARN|ERROR)\s+(?:(\S+::\S*?):\s+)?(.*)/) {
            let stamp = match.output.1.map(String.init)
            level = Level(rawValue: String(match.output.2))
            module = match.output.3.map(String.init)
            message = String(match.output.4)
            time = stamp.flatMap { Self.clock($0, timeZone: timeZone) }
        } else {
            message = trimmed
        }
    }

    /// `2026-10-09T10:00:03Z` (with or without fractions) as local `HH:mm:ss`; nil for any other text.
    static func clock(_ stamp: String, timeZone: TimeZone) -> String? {
        // The value-type ISO 8601 styles are safe to use from any place; with and without fractions.
        guard let date = (try? Date(stamp, strategy: .iso8601))
            ?? (try? Date(stamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02ld:%02ld:%02ld", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}

/// A journal row on screen: the first line of a run of identical lines, with how many lines the run has.
public struct JournalEntry: Equatable, Identifiable, Sendable {
    /// Index of the last line of the run in the source, so every row has its own id.
    public var id: Int
    /// The last line of the run: its time is the newest one.
    public var line: JournalLine
    /// How many lines the run has. One line shows no count.
    public var repeats: Int

    /// Groups consecutive lines that have the same level, module and message. The time is the newest line's.
    public static func collapsed(_ lines: [String], timeZone: TimeZone = .current) -> [JournalEntry] {
        var entries: [JournalEntry] = []
        for (index, text) in lines.enumerated() {
            let parsed = JournalLine(text, timeZone: timeZone)
            if let last = entries.last, last.line.level == parsed.level, last.line.module == parsed.module,
               last.line.message == parsed.message {
                entries[entries.count - 1] = JournalEntry(id: index, line: parsed, repeats: last.repeats + 1)
            } else {
                entries.append(JournalEntry(id: index, line: parsed, repeats: 1))
            }
        }
        return entries
    }
}
