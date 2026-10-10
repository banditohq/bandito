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
    /// Consecutive browser calls of the agent, shown as one live card (see `BrowserRunCard`).
    case browserRun([ToolRow])
}

extension ThreadRow: Identifiable {
    /// Stable across updates, so a row keeps its identity (and its entrance animation) when others arrive.
    public var id: String {
        switch self {
        case .day(let date): "day-\(date.timeIntervalSince1970)"
        case .chapter(let number, _): "chapter-\(number)"
        case .item(let item): item.id
        case .toolGroup(let tools): "tools-\(tools.first?.callId ?? "")"
        case .browserRun(let tools): "browser-\(tools.first?.callId ?? "")"
        }
    }
}

public enum ThreadRows {
    /// Builds the rows of a thread. Items without a timestamp (streams, tools, approvals) stay in the day they follow.
    public static func build(_ items: [ThreadItem], calendar: Calendar = .current) -> [ThreadRow] {
        var rows: [ThreadRow] = []
        var pending: [ToolRow] = []
        var lastDay: Date?

        /// Tool calls go out as runs: browser calls as a browser card, the rest as a command group, in order.
        func flushTools() {
            var run: [ToolRow] = []
            var runIsBrowser = false
            for tool in pending {
                let isBrowser = WorkbenchRules.isBrowserTool(tool.tool)
                if !run.isEmpty, isBrowser != runIsBrowser {
                    rows.append(runIsBrowser ? .browserRun(run) : .toolGroup(run))
                    run = []
                }
                runIsBrowser = isBrowser
                run.append(tool)
            }
            if !run.isEmpty {
                rows.append(runIsBrowser ? .browserRun(run) : .toolGroup(run))
            }
            pending = []
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
    static func timestamp(of item: ThreadItem) -> Int64? { item.timestamp }
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

/// The chapter length (context budget) a person can pick, in tokens.
public enum ChapterLength {
    /// The sizes offered in the menu. The default (`ContextUsage.defaultBudget`) is one of them.
    public static let presets = [60_000, 120_000, 200_000, 500_000, 1_000_000]
    /// The smallest and the largest budget the daemon accepts (`check_context_budget`).
    public static let allowedRange = 20_000...1_000_000

    /// `60K`, `120K`, `250K`, `1M`; a value with a tenth gets a decimal comma: `1,5M`.
    public static func label(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return unit(tokens, scale: 1_000_000) + "M"
        }
        return unit(tokens, scale: 1_000) + "K"
    }

    /// True when the daemon accepts the budget and the model can hold it. An unknown window (`nil`) only
    /// leaves the daemon's range to check.
    public static func isAllowed(_ tokens: Int, window: Int?) -> Bool {
        guard allowedRange.contains(tokens) else { return false }
        guard let window else { return true }
        return tokens <= window
    }

    /// The custom field's text for a size: thousands, with a decimal comma when there is a fraction (`250,5`).
    public static func thousandsText(_ tokens: Int) -> String {
        let whole = tokens / 1_000
        let rest = tokens % 1_000
        guard rest > 0 else { return "\(whole)" }
        var digits = String(rest)
        digits = String(repeating: "0", count: 3 - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(whole),\(digits)"
    }

    /// The text of the custom field as typed: digits and one decimal separator (a dot becomes a comma), at most
    /// 12 characters.
    public static func cleanedInput(_ text: String) -> String {
        var out = ""
        var separated = false
        for ch in text {
            if ch.isASCII && ch.isNumber {
                out.append(ch)
            } else if ch == "," || ch == ".", !separated, !out.isEmpty {
                out.append(",")
                separated = true
            }
        }
        return String(out.prefix(12))
    }

    /// The tokens a typed count of thousands stands for: `250,5` and `250.5` give 250 500, and `1,2345` gives 1 235
    /// (rounded to a whole token). Nil when the text is not a number. The range is not checked here.
    public static func parseThousands(_ text: String) -> Int? {
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." })
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty, whole.allSatisfy({ isDigit($0) }),
              let count = Int(whole), count <= 1_000_000
        else { return nil }
        var tokens = count * 1_000
        if parts.count == 2 {
            let decimals = parts[1]
            guard decimals.allSatisfy({ isDigit($0) }) else { return nil }
            if !decimals.isEmpty {
                let kept = decimals.prefix(15)
                var scale = 1
                for _ in kept { scale *= 10 }
                let numerator = Int(kept) ?? 0
                // Thousands to tokens, rounded half up.
                tokens += (numerator * 2_000 + scale) / (2 * scale)
            }
        }
        return tokens
    }

    /// What the custom field says about a size. Pure, so the rules are tested without the view.
    public static func customSize(_ text: String, current: Int, window: Int?) -> CustomSize {
        if text.isEmpty { return .empty }
        guard let tokens = parseThousands(text), allowedRange.contains(tokens) else { return .invalid }
        if let window, tokens > window { return .aboveWindow(tokens) }
        if tokens == current { return .unchanged(tokens) }
        return .ok(tokens)
    }

    private static func isDigit(_ ch: Character) -> Bool {
        ch.isASCII && ch.isNumber
    }

    /// The whole part and, when there is one, the first decimal of `tokens / scale`, truncated.
    private static func unit(_ tokens: Int, scale: Int) -> String {
        let whole = tokens / scale
        let tenth = (tokens % scale) * 10 / scale
        return tenth == 0 ? "\(whole)" : "\(whole),\(tenth)"
    }
}

/// What the custom chapter length field says about a typed size: why it cannot be saved, or the size when it can.
public enum CustomSize: Equatable, Sendable {
    case empty
    /// Not a number, or outside the daemon's range.
    case invalid
    /// In range, but more than the model holds (the size in tokens).
    case aboveWindow(Int)
    /// The size the agent already has.
    case unchanged(Int)
    /// A new size that can be saved (in tokens).
    case ok(Int)

    /// The size to save, when the text is a new valid size.
    public var savable: Int? {
        guard case .ok(let tokens) = self else { return nil }
        return tokens
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
