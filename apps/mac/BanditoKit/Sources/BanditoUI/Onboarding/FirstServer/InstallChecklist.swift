import BanditoKit
import Foundation

/// The five things the install does, as the person sees them.
enum ChecklistItem: Int, CaseIterable, Sendable {
    case connect, check, install, service, app
}

enum ChecklistMark: Equatable, Sendable {
    case pending, running, done, failed
}

/// The live checklist of an install. Driven by `InstallEvent`s: a step marks everything before it done and itself
/// running; a failure marks the running item failed and leaves the rest pending; a retry starts from `reset()`.
struct InstallChecklist: Equatable, Sendable {
    static let logLimit = 300

    private(set) var marks: [ChecklistMark] = Array(repeating: .pending, count: ChecklistItem.allCases.count)
    /// The installer's output, newest last, for the expandable log.
    private(set) var log: [String] = []
    private(set) var failure: InstallError?

    func mark(of item: ChecklistItem) -> ChecklistMark {
        marks[item.rawValue]
    }

    mutating func apply(_ event: InstallEvent) {
        switch event {
        case .step(let text):
            guard let item = Self.item(forStep: text) else { return }
            for index in 0..<item.rawValue where marks[index] != .failed {
                marks[index] = .done
            }
            marks[item.rawValue] = .running
        case .log(let line):
            log.append(line)
            if log.count > Self.logLimit {
                log.removeFirst(log.count - Self.logLimit)
            }
        case .done:
            marks = marks.map { _ in .done }
        case .failed(let error):
            let current = marks.firstIndex(of: .running) ?? ChecklistItem.connect.rawValue
            marks[current] = .failed
            failure = error
        }
    }

    /// Back to the start: for a retry.
    mutating func reset() {
        self = InstallChecklist()
    }

    /// The item a step text belongs to. The installer's step texts are fixed; an unknown text is nil.
    static func item(forStep text: String) -> ChecklistItem? {
        if text.contains("Checking") { return .check }
        if text.contains("Installing") || text.contains("Downloading") || text.contains("Verifying") { return .install }
        if text.contains("Starting") { return .service }
        if text.contains("pairing") || text.contains("Connecting") { return .app }
        return nil
    }
}
