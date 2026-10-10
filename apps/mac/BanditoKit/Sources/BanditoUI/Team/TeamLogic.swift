import BanditoKit
import BanditoL10n
import Foundation

// MARK: - Thread rows

/// One row of the thread as shown: consecutive tool calls are one group, days and chapters are dividers.
public enum ThreadRow: Sendable {
    /// Start of a calendar day (local time).
    case day(Date)
    /// Start of a memory chapter; `saved` is false when its memory was not saved.
    case chapter(number: Int, saved: Bool)
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
        case .chapter(let number, _): "chapter-\(number)"
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
            if case .chapter(_, let number, let saved, _) = item {
                rows.append(.chapter(number: number, saved: saved))
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
        case .chapter(_, _, _, let ts): ts
        case .streaming, .tool, .approval: nil
        }
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

// MARK: - Team sidebar: preview, order, the agent on screen

/// What the sidebar says about an agent's last message. The loaded thread wins when it has a message, else the
/// daemon's `last_message` (the thread is not loaded until the agent is opened).
public enum AgentPreview {
    public static func text(thread: AgentThread, agent: Agent) -> String? {
        thread.lastMessageText ?? agent.lastMessage?.text
    }

    /// The time shown on the row: the newest of the thread's last event and the daemon's last message. Without
    /// either, the last finished turn, else the last update.
    public static func timestamp(thread: AgentThread, agent: Agent) -> Int64 {
        let fromThread = thread.items.reversed().lazy.compactMap { ThreadRows.timestamp(of: $0) }.first
        return [fromThread, agent.lastMessage?.ts].compactMap { $0 }.max() ?? agent.lastTurnAt ?? agent.updatedAt
    }
}

/// The order the team sidebar shows agents in, and so what "the first one" means: the pinned tiles at the top,
/// then the agents that need a person, then the rest. Each group keeps the order it is given (`sortedAgents`).
public enum TeamSidebarOrder {
    /// The pinned row shows at most this many pinned agents, and scrolls sideways when they do not fit. A further pin
    /// stays pinned but is not in the row: it sorts with the rest.
    public static let pinnedTiles = 8

    public static func ids(agents: [Agent], pinned: Set<String>, needsPerson: (String) -> Bool) -> [String] {
        let tiles = agents.filter { pinned.contains($0.id) }.prefix(pinnedTiles).map(\.id)
        let waiting = agents.filter { needsPerson($0.id) }.map(\.id)
        var out: [String] = []
        for id in tiles + waiting + agents.map(\.id) where !out.contains(id) {
            out.append(id)
        }
        return out
    }
}

/// The agent the team shows on a server, and so the one highlighted in the sidebar.
public enum TeamSelection {
    /// The chosen agent when it is on this server; else the one last chosen here; else the first in sidebar order.
    /// Nil when the server has no agents.
    public static func resolve(selected: String?, remembered: String?, order: [String]) -> String? {
        LastOpenedAgent.resolve(selected: selected, remembered: remembered, agentIDs: order)
    }

    /// The agent the team shows now: `resolve` over this server's sidebar order.
    @MainActor
    public static func shownAgentID(server: ServerModel, selected: String?, pinned: Set<String>) -> String? {
        let order = TeamSidebarOrder.ids(agents: server.sortedAgents, pinned: pinned) { server.needsPerson($0) }
        return resolve(
            selected: selected,
            remembered: LastOpenedAgent.load(serverID: server.id.uuidString),
            order: order)
    }

    /// What the choice becomes once the shown agent is on screen: the shown agent is kept as the chosen one, so it
    /// stays on screen when the sidebar order changes (an approval elsewhere, a status change). Not saved: only an
    /// explicit choice is remembered (`Router.selectAgent`).
    public static func keptChoice(shown: String?) -> String? {
        shown
    }
}
