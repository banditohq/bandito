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
                cards: cards(from: server.usage, agentCounts: counts), isExample: false, updatedAt: updated)
        }
        if let demo, demo.enabled {
            return UsageSnapshot(cards: demoCards(demo), isExample: true, updatedAt: demo.startedAt)
        }
        return UsageSnapshot(cards: [], isExample: false, updatedAt: nil)
    }

    /// Cards for the daemon's entries. Runtimes come in a fixed order; unknown ones follow.
    public static func cards(from entries: [UsageEntry], agentCounts: [String: Int]) -> [UsageCard] {
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
                windows: entry.windows.map { window in
                    UsageWindowLine(
                        id: window.name,
                        label: windowLabel(window.name),
                        remaining: 1 - min(max(window.utilization, 0), 1),
                        resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        note: nil)
                })
        }
    }

    /// The smallest share left across the windows of `runtime`'s card, or across all cards when
    /// there is no runtime or no card for it. `nil` when there are no windows at all.
    public static func percentLeft(_ cards: [UsageCard], runtime: String?) -> Double? {
        let scoped = runtime.flatMap { id in cards.first { $0.runtime == id }.map { [$0] } } ?? cards
        return scoped.flatMap(\.windows).map(\.remaining).min()
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

    static func windowLabel(_ name: String) -> String {
        switch name {
        case "five_hour", "5h": L10n.Inspector.Window.fiveHour
        case "seven_day": L10n.Inspector.Window.sevenDay
        default: name
        }
    }
}

/// One line of the usage popover: a runtime's card, or a runtime that has no limits yet. `error` is the daemon's
/// reason the last refresh could not read it, shown in grey.
public enum UsageRow: Identifiable, Hashable, Sendable {
    case card(UsageCard, error: String?)
    case waiting(runtime: String, name: String, text: String, error: String?)

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
            .map { .card($0, error: errors[$0.runtime]) }
        for runtime in installed {
            if signedOut.contains(runtime) {
                rows.append(.waiting(
                    runtime: runtime, name: UsageCards.displayName(runtime),
                    text: L10n.AgentSheet.statusNeedsLogin, error: errors[runtime]))
            } else if !cards.contains(where: { $0.runtime == runtime }) {
                rows.append(.waiting(
                    runtime: runtime, name: UsageCards.displayName(runtime),
                    text: runtime == "claude" ? L10n.Usage.claudeWaitsForReply : L10n.Usage.noLimitsYet,
                    error: errors[runtime]))
            }
        }
        return rows.sorted { (rank($0.id), $0.id) < (rank($1.id), $1.id) }
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
