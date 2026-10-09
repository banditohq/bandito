import BanditoKit
import BanditoL10n
import Foundation

/// One line of the checklist, as the person sees it: its title, and the install steps it covers. A step belongs to a
/// line by its `InstallStep`, never by its text. The first step of a line that starts marks the line running.
struct ChecklistItem: Equatable, Sendable {
    var title: String
    var steps: Set<InstallStep>

    /// This Mac: Bandito is copied and started here, then the app connects to it. No SSH.
    static var thisMac: [ChecklistItem] {
        [
            ChecklistItem(title: L10n.Onboarding.Install.localInstall, steps: [.install]),
            ChecklistItem(title: L10n.Onboarding.Install.localStart, steps: [.service]),
            ChecklistItem(title: L10n.Onboarding.Install.localPair, steps: [.pair]),
        ]
    }

    /// Your own server: the SSH connection, the check, the install (download, verify, copy and run), the start,
    /// and the app's connection.
    static var ssh: [ChecklistItem] {
        [
            ChecklistItem(title: L10n.Onboarding.Install.connect, steps: [.connect]),
            ChecklistItem(title: L10n.Onboarding.Install.check, steps: [.check]),
            ChecklistItem(title: L10n.Onboarding.Install.install, steps: [.download, .verify, .install]),
            ChecklistItem(title: L10n.Onboarding.Install.service, steps: [.service]),
            ChecklistItem(title: L10n.Onboarding.Install.app, steps: [.pair]),
        ]
    }
}

enum ChecklistMark: Equatable, Sendable {
    case pending, running, done, failed
}

/// One line of the install journal: a step's text or an installer line, with the time it arrived.
struct JournalLine: Equatable, Sendable {
    let date: Date
    let text: String
}

/// The live checklist of an install, for one set of lines (`items`). Driven by `InstallEvent`s: a step marks every
/// line before its line done and its own line running; a failure marks the running line failed and leaves the rest
/// pending; a retry starts from `reset()`.
struct InstallChecklist: Equatable, Sendable {
    static let logLimit = 300

    /// The lines, in order.
    let items: [ChecklistItem]
    private(set) var marks: [ChecklistMark]
    /// The journal of this attempt, newest last: step texts, installer output and the final error.
    private(set) var journal: [JournalLine] = []
    /// Counts every journal line ever added. Unlike `journal.count`, it keeps growing after the journal is trimmed,
    /// so a view can scroll to the newest line when it changes.
    private(set) var journalVersion = 0
    private(set) var failure: InstallError?

    init(items: [ChecklistItem] = ChecklistItem.ssh) {
        self.items = items
        self.marks = Array(repeating: .pending, count: items.count)
    }

    /// The journal texts without their times.
    var log: [String] {
        journal.map(\.text)
    }

    /// The journal as shown and copied: each line starts with its time, HH:mm:ss.
    var formattedLog: [String] {
        journal.map { Self.timestamp($0.date) + "  " + $0.text }
    }

    func mark(at index: Int) -> ChecklistMark {
        marks[index]
    }

    /// The index of the line that covers `step`, or nil when this checklist has no such line.
    func index(of step: InstallStep) -> Int? {
        items.firstIndex { $0.steps.contains(step) }
    }

    /// `at` is the time written in front of the journal line of this event. Steps and log lines are both kept.
    mutating func apply(_ event: InstallEvent, at date: Date = Date()) {
        switch event {
        case .step(let step, let text):
            guard let index = index(of: step) else {
                if !text.isEmpty { appendToLog(text, at: date) }
                return
            }
            for earlier in 0..<index where marks[earlier] != .failed {
                marks[earlier] = .done
            }
            marks[index] = .running
            if !text.isEmpty { appendToLog(text, at: date) }
        case .log(let line):
            appendToLog(line, at: date)
        case .done:
            marks = marks.map { _ in .done }
        case .failed(let error):
            let current = marks.firstIndex(of: .running) ?? 0
            if !marks.isEmpty {
                marks[current] = .failed
            }
            failure = error
            appendToLog(Self.text(of: error), at: date)
        }
    }

    /// Marks the last line failed. For a failure after the installer has finished, when the last line is already done
    /// (the app could not keep the server, or the connection did not come up).
    mutating func failLast(_ error: InstallError, at date: Date = Date()) {
        guard !marks.isEmpty else { return }
        marks[marks.count - 1] = .failed
        failure = error
        appendToLog(Self.text(of: error), at: date)
    }

    /// The full text of an error, as the journal ends with it.
    static func text(of error: InstallError) -> String {
        error.errorDescription ?? "\(error)"
    }

    /// Adds a journal line. The journal stays within `logLimit` lines.
    private mutating func appendToLog(_ text: String, at date: Date) {
        journal.append(JournalLine(date: date, text: text))
        journalVersion += 1
        if journal.count > Self.logLimit {
            journal.removeFirst(journal.count - Self.logLimit)
        }
    }

    /// The local time as HH:mm:ss, in the same form in every language.
    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// One formatter for all journal lines. Only read after it is created.
    nonisolated(unsafe) private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Back to the start of the same lines: for a retry.
    mutating func reset() {
        self = InstallChecklist(items: items)
    }
}
