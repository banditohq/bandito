import BanditoKit
import BanditoL10n
import Foundation

// MARK: - Thread rows

/// One row of the thread as shown: consecutive tool calls are one group, days and chapters are dividers.
public enum ThreadRow: Sendable {
    /// Start of a calendar day (local time).
    case day(Date)
    /// Start of a memory chapter, from a `Chapter N · …` note.
    case chapter(Int)
    /// Any other item, shown as it is.
    case item(ThreadItem)
    /// Consecutive tool calls, shown as one card.
    case toolGroup([ToolRow])
}

extension ThreadRow: Identifiable {
    /// Stable across updates, so a row keeps its identity (and its entrance animation) when others arrive.
    public var id: String {
        switch self {
        case .day(let date): "day-\(date.timeIntervalSince1970)"
        case .chapter(let number): "chapter-\(number)"
        case .item(let item): item.id
        case .toolGroup(let tools): "tools-\(tools.first?.callId ?? "")"
        }
    }
}

public enum ThreadRows {
    /// Builds the rows of a thread. Items without a timestamp (streams, tools, approvals) stay in the day they follow.
    public static func build(_ items: [ThreadItem], calendar: Calendar = .current) -> [ThreadRow] {
        var rows: [ThreadRow] = []
        var pending: [ToolRow] = []
        var lastDay: Date?

        func flushTools() {
            if !pending.isEmpty {
                rows.append(.toolGroup(pending))
                pending = []
            }
        }

        for item in items {
            if case .tool(let row) = item {
                pending.append(row)
                continue
            }
            flushTools()
            if let ts = timestamp(of: item) {
                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(ts) / 1000))
                if day != lastDay {
                    rows.append(.day(day))
                    lastDay = day
                }
            }
            if case .note(_, let text, _, _) = item, let number = chapterNumber(in: text) {
                rows.append(.chapter(number))
            } else {
                rows.append(.item(item))
            }
        }
        flushTools()
        return rows
    }

    /// Timestamp in Unix milliseconds, when the item has one.
    static func timestamp(of item: ThreadItem) -> Int64? {
        switch item {
        case .user(_, _, _, _, let ts), .assistant(_, _, let ts), .note(_, _, _, let ts): ts
        case .runtimeSwitch(_, _, _, _, let ts): ts
        case .streaming, .tool, .approval: nil
        }
    }

    /// The number in a `Chapter N · …` note, which the daemon writes when a session rotates.
    static func chapterNumber(in text: String) -> Int? {
        guard text.hasPrefix("Chapter ") else { return nil }
        let digits = text.dropFirst("Chapter ".count).prefix { $0.isNumber }
        return Int(digits)
    }
}

// MARK: - Context

public enum ContextUsage {
    /// Context budget used when the agent has none set. Matches the chapter size shown in the design.
    public static let defaultBudget = 120_000

    /// Share of the context window in use, 0 to 1. A missing budget means the default; a zero budget means no share.
    public static func fraction(tokens: Int, budget: Int?) -> Double {
        let limit = budget ?? defaultBudget
        guard limit > 0 else { return 0 }
        return min(max(Double(tokens) / Double(limit), 0), 1)
    }
}

// MARK: - Effort

public enum EffortLevels {
    /// Effort levels a runtime accepts, from least to most.
    public static func levels(for runtime: RuntimeKind) -> [Effort] {
        switch runtime {
        case .claude, .api: [.low, .medium, .high, .xhigh, .max]
        case .codex: [.low, .medium, .high, .xhigh]
        case .grok: [.low, .medium, .high]
        }
    }
}

// MARK: - Pins

/// Agents pinned to the top of the team sidebar. Kept on this Mac only, in `UserDefaults`.
public struct PinnedAgents {
    public static let key = "pinned.agents"

    public private(set) var ids: [String]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = defaults.stringArray(forKey: Self.key) ?? []
    }

    public func isPinned(_ id: String) -> Bool {
        ids.contains(id)
    }

    /// Pins the agent if it is not pinned, unpins it otherwise. The new list is saved at once.
    public mutating func toggle(_ id: String) {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        defaults.set(ids, forKey: Self.key)
    }
}

// MARK: - Labels

extension RuntimeKind {
    /// Name of the runtime as the people see it.
    var title: String {
        switch self {
        case .claude: L10n.Runtime.claude
        case .codex: L10n.Runtime.codex
        case .grok: L10n.Runtime.grok
        case .api: L10n.Runtime.api
        }
    }
}

extension Effort {
    /// Localized name of the effort level.
    var title: String {
        switch self {
        case .low: L10n.Effort.low
        case .medium: L10n.Effort.medium
        case .high: L10n.Effort.high
        case .xhigh: L10n.Effort.xhigh
        case .max: L10n.Effort.max
        }
    }
}

extension AgentStatus {
    /// Localized status word, as in the header of the thread.
    var title: String {
        switch self {
        case .idle: L10n.Status.idle
        case .working: L10n.Status.working
        case .needsYou: L10n.Status.needsYou
        case .error: L10n.Status.error
        case .offline: L10n.Status.offline
        }
    }
}

enum TeamTime {
    /// `14:02` for today, a short weekday for this week, a date otherwise.
    static func label(ms: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
