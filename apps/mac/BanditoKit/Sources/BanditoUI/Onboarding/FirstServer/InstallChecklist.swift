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

/// The live checklist of an install, for one set of lines (`items`). Driven by `InstallEvent`s: a step marks every
/// line before its line done and its own line running; a failure marks the running line failed and leaves the rest
/// pending; a retry starts from `reset()`.
struct InstallChecklist: Equatable, Sendable {
    static let logLimit = 300

    /// The lines, in order.
    let items: [ChecklistItem]
    private(set) var marks: [ChecklistMark]
    /// The installer's output, newest last, for the expandable log.
    private(set) var log: [String] = []
    private(set) var failure: InstallError?

    init(items: [ChecklistItem] = ChecklistItem.ssh) {
        self.items = items
        self.marks = Array(repeating: .pending, count: items.count)
    }

    func mark(at index: Int) -> ChecklistMark {
        marks[index]
    }

    /// The index of the line that covers `step`, or nil when this checklist has no such line.
    func index(of step: InstallStep) -> Int? {
        items.firstIndex { $0.steps.contains(step) }
    }

    mutating func apply(_ event: InstallEvent) {
        switch event {
        case .step(let step, _):
            guard let index = index(of: step) else { return }
            for earlier in 0..<index where marks[earlier] != .failed {
                marks[earlier] = .done
            }
            marks[index] = .running
        case .log(let line):
            log.append(line)
            if log.count > Self.logLimit {
                log.removeFirst(log.count - Self.logLimit)
            }
        case .done:
            marks = marks.map { _ in .done }
        case .failed(let error):
            let current = marks.firstIndex(of: .running) ?? 0
            if !marks.isEmpty {
                marks[current] = .failed
            }
            failure = error
        }
    }

    /// Marks the last line failed. For a failure after the installer has finished, when the last line is already done
    /// (the app could not keep the server, or the connection did not come up).
    mutating func failLast(_ error: InstallError) {
        guard !marks.isEmpty else { return }
        marks[marks.count - 1] = .failed
        failure = error
    }

    /// Back to the start of the same lines: for a retry.
    mutating func reset() {
        self = InstallChecklist(items: items)
    }
}
