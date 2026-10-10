import BanditoKit
import BanditoL10n
import Foundation

/// One subscription (or API budget) as the usage popover and the sidebar button read it.
public struct UsageCard: Identifiable, Hashable, Sendable {
    public var id: String { runtime }
    /// The runtime id: "claude", "codex", "grok", "api".
    public let runtime: String
    public let name: String
    /// The plan chip, e.g. "Max ×20". `nil` when unknown.
    public let plan: String?
    public let color: AvatarColor
    /// Who uses it, e.g. "3 agents". `nil` when nobody does.
    public let who: String?
    public let windows: [UsageWindowLine]
}

/// One limit window of a card: how much is left and when it resets.
public struct UsageWindowLine: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    /// Share of the window left, 0...1.
    public let remaining: Double
    public let resetsAt: Date?
    /// Shown under the bar instead of the countdown, for windows without a reset.
    public let note: String?

    public var exhausted: Bool { remaining <= 0 }

    /// Share of the window used, 0...1. Read from `remaining` clamped to 0...1, so a value outside that range
    /// cannot take the bar past its ends.
    public var used: Double { 1 - UsageWindowLine.clampedShare(remaining) }

    /// `value` clamped to 0...1. NaN counts as a full share left (nothing used).
    static func clampedShare(_ value: Double) -> Double {
        value.isNaN ? 1 : min(max(value, 0), 1)
    }
}

/// Builds the usage cards from the server's limits, or from the sample data when the server has none.
public enum UsageCards {
    /// Cards to show and whether they are sample data.
    @MainActor
    public static func snapshot(server: ServerModel?, demo: DemoStore?, now: Date = Date()) -> UsageSnapshot {
        if let server, !server.usage.isEmpty {
            var counts: [String: Int] = [:]
            for agent in server.agents {
                counts[agent.runtime.rawValue, default: 0] += 1
            }
            let updated = server.usage.map { Date(timeIntervalSince1970: TimeInterval($0.updatedAt) / 1000) }.max()
            return UsageSnapshot(
                cards: cards(from: server.usage, agentCounts: counts, now: now), isExample: false, updatedAt: updated)
        }
        if let demo, demo.enabled {
            return UsageSnapshot(cards: demoCards(demo), isExample: true, updatedAt: demo.startedAt)
        }
        return UsageSnapshot(cards: [], isExample: false, updatedAt: nil)
    }

    /// Cards for the daemon's entries. Runtimes come in a fixed order; unknown ones follow. Windows come shortest
    /// first (see `windowMinutes`). A window whose reset time is already past has reset: it reads as unused and has
    /// no countdown, until the limits are refreshed.
    public static func cards(from entries: [UsageEntry], agentCounts: [String: Int], now: Date = Date()) -> [UsageCard] {
        let order = ["claude", "codex", "grok", "api"]
        return entries.sorted { lhs, rhs in
            (order.firstIndex(of: lhs.runtime) ?? order.count) < (order.firstIndex(of: rhs.runtime) ?? order.count)
        }
        .map { entry in
            let count = agentCounts[entry.runtime] ?? 0
            return UsageCard(
                runtime: entry.runtime,
                name: displayName(entry.runtime),
                plan: entry.plan?.label,
                color: color(entry.runtime),
                who: count > 0 ? L10n.Common.agentCount(count: count) : nil,
                windows: sortedWindows(entry.windows).map { window in
                    let reset = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    let passed = reset.map { $0 <= now } ?? false
                    return UsageWindowLine(
                        id: window.name,
                        label: windowLabel(window.name),
                        remaining: passed ? 1 : 1 - min(max(window.utilization, 0), 1),
                        resetsAt: passed ? nil : reset,
                        note: nil)
                })
        }
    }

    /// The latest reset among the used-up windows (100% used) that is still ahead: the time the runtime is back. A reset
    /// in the past is a stale value of a window that has already reset, so it does not count.
    public static func exhaustedReset(_ windows: [UsageWindowLine], now: Date) -> Date? {
        windows.filter(\.exhausted).compactMap(\.resetsAt).filter { $0 > now }.max()
    }

    /// The windows shortest first; a window of unknown length goes last, in the order the daemon sent it.
    public static func sortedWindows(_ windows: [LimitWindow]) -> [LimitWindow] {
        windows.enumerated().sorted { lhs, rhs in
            let left = windowMinutes(lhs.element.name) ?? Int.max
            let right = windowMinutes(rhs.element.name) ?? Int.max
            return left != right ? left < right : lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    /// The length of a limit window in minutes, read from its name: `five_hour`/`5h` 300, `one_day`/`daily`/`1d` 1440,
    /// `seven_day`/`weekly` and `seven_day_<model>` 10080, `<N>m` N. `nil` for any other name.
    public static func windowMinutes(_ name: String) -> Int? {
        switch name {
        case "five_hour", "5h": return 300
        case "one_day", "daily", "1d": return 1440
        case "seven_day", "weekly": return 10080
        default: break
        }
        if name.hasPrefix("seven_day_") { return 10080 }
        if name.hasSuffix("m"), let minutes = Int(name.dropLast()), minutes > 0 { return minutes }
        return nil
    }

    /// The smallest share left across the windows of `runtime`'s card, or across all cards when
    /// there is no runtime or no card for it. `nil` when there are no windows at all.
    public static func percentLeft(_ cards: [UsageCard], runtime: String?) -> Double? {
        let scoped = runtime.flatMap { id in cards.first { $0.runtime == id }.map { [$0] } } ?? cards
        return scoped.flatMap(\.windows).map(\.remaining).min()
    }

    /// The most filled window across the windows of `runtime`'s card, or across all cards when there is no
    /// runtime or no card for it. On a tie the first one wins. `nil` when there are no windows at all.
    public static func fullestWindow(_ cards: [UsageCard], runtime: String?) -> FullestWindow? {
        let scoped = runtime.flatMap { id in cards.first { $0.runtime == id }.map { [$0] } } ?? cards
        let lines = scoped.flatMap { card in card.windows.map { (card: card, window: $0) } }
        // `max(by:)` keeps the first of equal elements, so a tie goes to the window listed first.
        guard let fullest = lines.max(by: { $0.window.used < $1.window.used }) else { return nil }
        return FullestWindow(
            runtimeName: RuntimeKind(rawValue: fullest.card.runtime)?.title ?? fullest.card.name,
            windowLabel: fullest.window.label,
            used: fullest.window.used)
    }

    @MainActor
    static func demoCards(_ demo: DemoStore) -> [UsageCard] {
        demo.usage.map { usage in
            UsageCard(
                runtime: usage.runtime,
                name: usage.name,
                plan: usage.plan,
                color: usage.color,
                who: usage.who,
                windows: usage.windows.enumerated().map { index, window in
                    UsageWindowLine(
                        id: "\(index)",
                        label: window.label,
                        remaining: window.remaining,
                        resetsAt: window.resetsAt,
                        note: window.note)
                })
        }
    }

    /// What a runtime without limits says: Claude reports them after its first reply, Grok does not report them at all.
    static func waitingText(_ runtime: String) -> String {
        switch runtime {
        case "claude": L10n.Usage.claudeWaitsForReply
        case "grok": L10n.Usage.grokNoLimits
        default: L10n.Usage.noLimitsYet
        }
    }

    static func displayName(_ runtime: String) -> String {
        switch runtime {
        case "claude": "Claude"
        case "codex": "Codex"
        case "grok": "Grok"
        case "api": L10n.Runtime.api
        default: runtime
        }
    }

    static func color(_ runtime: String) -> AvatarColor {
        switch runtime {
        case "claude": .peach
        case "codex": .sky
        case "grok": .sage
        case "api": .lilac
        default: .cream
        }
    }

    /// The name of a window as people read it: "5 hours", "Day", "Week", "Week · Opus", "3 days", or the name itself
    /// with spaces and a capital, for a window this app does not know.
    static func windowLabel(_ name: String) -> String {
        switch name {
        case "five_hour", "5h": return L10n.Inspector.Window.fiveHour
        case "seven_day", "weekly": return L10n.Inspector.Window.sevenDay
        case "one_day", "daily", "1d": return L10n.Usage.Window.day
        default: break
        }
        if name.hasPrefix("seven_day_") {
            let model = humanized(String(name.dropFirst("seven_day_".count)))
            return model.isEmpty ? L10n.Inspector.Window.sevenDay : L10n.Usage.Window.weekModel(model: model)
        }
        if let minutes = windowMinutes(name), name.hasSuffix("m") {
            return durationLabel(minutes: minutes)
        }
        return humanized(name)
    }

    /// A length in minutes as people say it: "Day", "3 days", "12 hours", "1 hour", "90 min".
    static func durationLabel(minutes: Int) -> String {
        if minutes % 1440 == 0 {
            let days = minutes / 1440
            return days == 1 ? L10n.Usage.Window.day : L10n.Usage.Window.days(count: days)
        }
        if minutes % 60 == 0 {
            return L10n.Usage.Window.hours(count: minutes / 60)
        }
        return L10n.Usage.Window.minutes(minutes: "\(minutes)")
    }

    /// "weird_name" → "Weird name".
    static func humanized(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }
}

/// The most filled limit window, as the sidebar button tells it: which runtime and window, and how much of it is used.
public struct FullestWindow: Hashable, Sendable {
    /// The runtime as people see it, e.g. "Claude Code".
    public let runtimeName: String
    /// The window's label, e.g. "5 hours".
    public let windowLabel: String
    /// Share of the window used, 0...1.
    public let used: Double

    /// The share used as a whole percent, e.g. 73.
    public var usedPercent: Int { Int((used * 100).rounded()) }
}

/// One line of the usage popover: a runtime's card, or a runtime that has no limits yet. `problem` says what went wrong
/// when the last refresh could not read it (see `UsageProblem`).
public enum UsageRow: Identifiable, Hashable, Sendable {
    case card(UsageCard, problem: UsageProblem?)
    /// A runtime without a card: its name, the line that says why, and the problem it had, if any.
    case waiting(runtime: String, name: String, text: String, problem: UsageProblem?)

    public var id: String {
        switch self {
        case .card(let card, _): card.runtime
        case .waiting(let runtime, _, _, _): runtime
        }
    }

    /// The popover's lines for the server's runtimes. Installed runtimes come first in a fixed order (then by id):
    /// a runtime that is not signed in says so; one with a card shows it; one without says its limits are to come.
    /// A card of a runtime the server reports as not installed is left out. With no runtime status yet, the cards
    /// are shown as they are.
    public static func make(cards: [UsageCard], runtimes: [RuntimeStatus], errors: [String: String]) -> [UsageRow] {
        let order = ["claude", "codex", "grok", "api"]
        func rank(_ runtime: String) -> Int { order.firstIndex(of: runtime) ?? order.count }
        let notInstalled = Set(runtimes.filter { !$0.installed }.map { $0.kind.rawValue })
        let signedOut = Set(runtimes.filter { $0.installed && $0.loggedIn == false }.map { $0.kind.rawValue })
        let installed = runtimes.filter(\.installed).map { $0.kind.rawValue }

        var rows: [UsageRow] = cards
            .filter { !notInstalled.contains($0.runtime) && !signedOut.contains($0.runtime) }
            .map { card in .card(card, problem: errors[card.runtime].map { UsageProblem.make(runtime: card.runtime, raw: $0) }) }
        for runtime in installed {
            if signedOut.contains(runtime) {
                // The signed-out line names the login command; the daemon's own words stay in the tooltip.
                rows.append(.waiting(
                    runtime: runtime, name: UsageCards.displayName(runtime),
                    text: L10n.AgentSheet.statusNeedsLogin,
                    problem: UsageProblem.needsLogin(runtime: runtime, raw: errors[runtime] ?? "")))
            } else if !cards.contains(where: { $0.runtime == runtime }) {
                rows.append(.waiting(
                    runtime: runtime, name: UsageCards.displayName(runtime),
                    text: UsageCards.waitingText(runtime),
                    problem: errors[runtime].map { UsageProblem.make(runtime: runtime, raw: $0) }))
            }
        }
        return rows.sorted { (rank($0.id), $0.id) < (rank($1.id), $1.id) }
    }
}

/// A runtime's usage error as people read it: what is wrong, and for a login the command that fixes it.
/// The daemon's words stay in `raw`, for the tooltip.
public struct UsageProblem: Hashable, Sendable {
    public enum Kind: Equatable, Sendable {
        case needsLogin
        case notInstalled
        case unknown
    }

    public let kind: Kind
    public let raw: String
    /// The command that signs the person in, for a login problem only.
    public let loginCommand: String?

    public static func make(runtime: String, raw: String) -> UsageProblem {
        let text = raw.lowercased()
        let loginWords = ["authentication", "unauthorized", "not logged in", "not signed in", "log in", "login", "sign in"]
        let installWords = ["command not found", "no such file", "is not installed"]
        if loginWords.contains(where: { text.contains($0) }) {
            return UsageProblem(kind: .needsLogin, raw: raw, loginCommand: loginCommand(runtime: runtime))
        }
        if installWords.contains(where: { text.contains($0) }) {
            return UsageProblem(kind: .notInstalled, raw: raw, loginCommand: nil)
        }
        return UsageProblem(kind: .unknown, raw: raw, loginCommand: nil)
    }

    /// A problem known to be a login: the runtime is installed but not signed in.
    public static func needsLogin(runtime: String, raw: String) -> UsageProblem {
        UsageProblem(kind: .needsLogin, raw: raw, loginCommand: loginCommand(runtime: runtime))
    }

    /// The command that signs the person in to `runtime`, e.g. "codex login"; nil for an unknown runtime.
    public static func loginCommand(runtime: String) -> String? {
        guard let kind = RuntimeKind(rawValue: runtime) else { return nil }
        return LoginCommand.arguments(for: kind).joined(separator: " ")
    }

    /// The line the card shows: "Sign-in needed", "Not installed on the server" or "Couldn't get the limits".
    public var title: String {
        switch kind {
        case .needsLogin: L10n.AgentSheet.statusNeedsLogin
        case .notInstalled: L10n.AgentSheet.statusNotInstalled
        case .unknown: L10n.Usage.Error.unknown
        }
    }
}

/// The cards plus where they came from.
public struct UsageSnapshot: Sendable {
    public let cards: [UsageCard]
    /// True when the cards are sample data (the server has no limits yet).
    public let isExample: Bool
    /// When the limits were last received.
    public let updatedAt: Date?

    public var hasExhaustedWindow: Bool {
        cards.contains { $0.windows.contains(where: \.exhausted) }
    }
}

/// Why a runtime has no block in the popover, in the words of its one-line summary.
public enum UsageOtherReason: Equatable, Sendable {
    case needsLogin
    case noLimits
    case noData
}

/// A runtime the popover names on its summary line instead of giving it a block.
public struct UsageOtherRuntime: Equatable, Sendable {
    public var runtime: String
    public var name: String
    public var reason: UsageOtherReason
}

extension UsageRow {
    /// Splits the popover's rows. A runtime gets a block when it has agents, or a subscription (a plan) or limit
    /// windows. Any other runtime goes on the one-line summary with its short reason. Pure, so the rule is tested.
    public static func split(
        _ rows: [UsageRow], agentRuntimes: Set<String>
    ) -> (blocks: [UsageRow], others: [UsageOtherRuntime]) {
        var blocks: [UsageRow] = []
        var others: [UsageOtherRuntime] = []
        for row in rows {
            switch row {
            case .card(let card, let problem):
                let hasData = !card.windows.isEmpty || card.plan != nil
                if hasData || agentRuntimes.contains(card.runtime) {
                    blocks.append(row)
                } else {
                    others.append(UsageOtherRuntime(
                        runtime: card.runtime, name: card.name, reason: reason(for: card.runtime, problem: problem)))
                }
            case .waiting(let runtime, let name, _, let problem):
                if agentRuntimes.contains(runtime) {
                    blocks.append(row)
                } else {
                    others.append(UsageOtherRuntime(runtime: runtime, name: name, reason: reason(for: runtime, problem: problem)))
                }
            }
        }
        return (blocks, others)
    }

    private static func reason(for runtime: String, problem: UsageProblem?) -> UsageOtherReason {
        if problem?.kind == .needsLogin { return .needsLogin }
        return runtime == "grok" ? .noLimits : .noData
    }
}

/// When the popover asks the runtimes again for limit windows that did not come. A subscription (a plan is known)
/// whose windows are missing gets one request, and not more often than `interval`.
public enum UsageWindowsRequest {
    /// Two minutes between such requests.
    public static let interval: TimeInterval = 120

    /// The popover's record of its last such request, shared by every opening in this launch.
    @MainActor
    static var lastAsked: Date?

    /// Whether to ask now. Pure: the caller keeps `lastAsked`.
    public static func isDue(entries: [UsageEntry], lastAsked: Date?, now: Date) -> Bool {
        guard entries.contains(where: { $0.plan != nil && $0.windows.isEmpty }) else { return false }
        guard let lastAsked else { return true }
        return now.timeIntervalSince(lastAsked) >= interval
    }
}

