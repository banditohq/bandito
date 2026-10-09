import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// Sample data from the design, shown under an "Example" chip where the server has no real data yet.
/// Real data always wins: screens use demo values only when the server lacks the feature.
@MainActor
@Observable
public final class DemoStore {
    public static let storageKey = "demo.enabled"

    @ObservationIgnored private let defaults: UserDefaults

    /// Whether sample data may be shown. Off by default (real users see only their own data); Settings → General → "Show examples".
    public var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.storageKey) }
    }

    /// When this store was created. Demo reset times count down from here.
    public let startedAt: Date
    public let agents: [DemoAgent]
    public let usage: [DemoUsage]
    public let files: [DemoFile]
    public let terminals: [DemoTerminal]
    public let workplaces: [DemoWorkplace]
    /// Server → Workplaces: where the agents live. Shown only when the server lacks the `workspaces` feature.
    public let spaces: [DemoSpace]
    public let serverLoad = DemoServerLoad(cpu: 0.34, memory: 0.58)

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.storageKey) as? Bool ?? false
        let start = Date()
        startedAt = start

        agents = [
            DemoAgent(
                name: "Forge", role: L10n.Demo.Role.builder, color: .peach, status: .needsYou,
                preview: L10n.Demo.Preview.forge),
            DemoAgent(
                name: "Scout", role: L10n.Demo.Role.reviewer, color: .sky, status: .idle,
                preview: L10n.Demo.Preview.scout),
            DemoAgent(
                name: "Watch", role: L10n.Demo.Role.onCall, color: .rose, status: .working,
                preview: L10n.Demo.Preview.watch),
            DemoAgent(
                name: "Night Owl", role: L10n.Demo.Role.auditor, color: .sage, status: .idle,
                preview: L10n.Demo.Preview.nightOwl),
            DemoAgent(
                name: "Quill", role: L10n.Demo.Role.docs, color: .lilac, status: .idle,
                preview: L10n.Demo.Preview.quill),
            DemoAgent(
                name: "Atlas", role: L10n.Demo.Role.lead, color: .cream, status: .working,
                preview: L10n.Demo.Preview.atlas),
        ]

        usage = [
            DemoUsage(
                runtime: "claude", name: "Claude", plan: "Max ×20", color: .peach,
                who: L10n.Common.agentCount(count: 3),
                windows: [
                    DemoWindow(
                        label: L10n.Inspector.Window.fiveHour, remaining: 0.90,
                        resetsAt: start.addingTimeInterval(2 * 3600 + 14 * 60)),
                    DemoWindow(
                        label: L10n.Inspector.Window.sevenDay, remaining: 0.77,
                        resetsAt: start.addingTimeInterval(5 * 86_400 + 20 * 3600)),
                ]),
            DemoUsage(
                runtime: "codex", name: "Codex", plan: "ChatGPT Plus", color: .sky, who: "Scout",
                windows: [
                    DemoWindow(
                        label: L10n.Inspector.Window.fiveHour, remaining: 0.18,
                        resetsAt: start.addingTimeInterval(41 * 60)),
                    DemoWindow(
                        label: L10n.Inspector.Window.sevenDay, remaining: 0.64,
                        resetsAt: start.addingTimeInterval(3 * 86_400 + 19 * 3600)),
                ]),
            DemoUsage(
                runtime: "grok", name: "Grok", plan: "SuperGrok", color: .sage, who: "Watch → Codex",
                windows: [
                    DemoWindow(
                        label: L10n.Demo.Window.day, remaining: 0,
                        resetsAt: start.addingTimeInterval(5 * 3600 + 48 * 60 + 12)),
                ]),
            DemoUsage(
                runtime: "api", name: L10n.Runtime.api, plan: "OpenRouter", color: .lilac, who: "Quill",
                windows: [
                    DemoWindow(
                        label: L10n.Demo.budget, remaining: 0.75, resetsAt: nil, note: L10n.Demo.budgetNote),
                ]),
        ]

        files = [
            DemoFile(name: "src", isFolder: true, change: nil),
            DemoFile(name: "tests", isFolder: true, change: nil),
            DemoFile(name: "webhook.ts", isFolder: false, change: "+412 −18"),
            DemoFile(name: "invoice.ts", isFolder: false, change: "+36 −4"),
            DemoFile(name: "README.md", isFolder: false, change: nil),
        ]

        terminals = [
            DemoTerminal(name: "deploy staging", state: .waiting),
            DemoTerminal(name: "cargo watch", state: .running),
        ]

        workplaces = [
            DemoWorkplace(name: "billing", path: "~/billing", agentName: "Forge"),
            DemoWorkplace(name: "api", path: "~/api", agentName: "Watch"),
            DemoWorkplace(name: "landing", path: "~/landing", agentName: "Quill"),
        ]

        spaces = [
            DemoSpace(
                name: L10n.Demo.Space.sharedName, kind: .shared, agents: ["Atlas", "Forge", "Quill"],
                rows: [
                    DemoSpaceRow(icon: "folder", label: L10n.Server.Workspaces.Row.files, value: L10n.Demo.Space.Shared.files),
                    DemoSpaceRow(icon: "globe", label: L10n.Server.Workspaces.Row.browser, value: L10n.Demo.Space.Shared.browser),
                    DemoSpaceRow(icon: "display", label: L10n.Server.Workspaces.Row.screen, value: L10n.Demo.Space.Shared.screen),
                    DemoSpaceRow(icon: "network", label: L10n.Server.Workspaces.Row.network, value: L10n.Demo.Space.Shared.network),
                ],
                meters: []),
            DemoSpace(
                name: L10n.Demo.Space.containerName, kind: .container, agents: ["Scout"],
                rows: [
                    DemoSpaceRow(icon: "folder", label: L10n.Server.Workspaces.Row.files, value: L10n.Demo.Space.Container.files),
                    DemoSpaceRow(icon: "globe", label: L10n.Server.Workspaces.Row.browser, value: L10n.Demo.Space.Container.browser),
                    DemoSpaceRow(icon: "display", label: L10n.Server.Workspaces.Row.screen, value: L10n.Demo.Space.Container.screen),
                    DemoSpaceRow(icon: "network", label: L10n.Server.Workspaces.Row.network, value: L10n.Demo.Space.Container.network),
                ],
                meters: [
                    DemoMeter(label: L10n.Demo.Space.cpu, value: L10n.Demo.Space.Container.cpuValue, fraction: 0.7),
                    DemoMeter(label: L10n.Demo.Space.memory, value: L10n.Demo.Space.Container.memoryValue, fraction: 0.55),
                ]),
            DemoSpace(
                name: L10n.Demo.Space.userName, kind: .user, agents: ["Watch"],
                rows: [
                    DemoSpaceRow(icon: "folder", label: L10n.Server.Workspaces.Row.files, value: L10n.Demo.Space.User.files),
                    DemoSpaceRow(icon: "globe", label: L10n.Server.Workspaces.Row.browser, value: L10n.Demo.Space.User.browser),
                    DemoSpaceRow(icon: "display", label: L10n.Server.Workspaces.Row.screen, value: L10n.Demo.Space.User.screen),
                    DemoSpaceRow(icon: "terminal", label: L10n.Server.Workspaces.Row.commands, value: L10n.Demo.Space.User.commands),
                ],
                meters: []),
        ]
    }
}

public struct DemoAgent: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let role: String
    public let color: AvatarColor
    public let status: AgentStatus
    public let preview: String
}

public struct DemoUsage: Identifiable, Hashable, Sendable {
    public var id: String { runtime }
    /// The runtime id the card belongs to: "claude", "codex", "grok", "api".
    public let runtime: String
    /// Brand name of the runtime, e.g. "Claude".
    public let name: String
    /// The plan name, e.g. "Max ×20".
    public let plan: String?
    public let color: AvatarColor
    /// Who uses this subscription, already written for the UI ("3 agents", "Scout").
    public let who: String
    public let windows: [DemoWindow]

    public init(
        runtime: String, name: String, plan: String?, color: AvatarColor, who: String, windows: [DemoWindow]
    ) {
        self.runtime = runtime
        self.name = name
        self.plan = plan
        self.color = color
        self.who = who
        self.windows = windows
    }
}

public struct DemoWindow: Hashable, Sendable {
    public let label: String
    /// Share of the window left, 0...1.
    public let remaining: Double
    /// When the window resets. `nil` for windows without a reset (budgets).
    public let resetsAt: Date?
    /// Shown under the bar instead of the countdown, e.g. "$12.40 of $50".
    public let note: String?

    public init(label: String, remaining: Double, resetsAt: Date?, note: String? = nil) {
        self.label = label
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.note = note
    }
}

public struct DemoFile: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let isFolder: Bool
    /// The change stats of a file the agent touched, e.g. "+412 −18".
    public let change: String?
}

public struct DemoTerminal: Identifiable, Hashable, Sendable {
    public enum State: Sendable { case waiting, running }

    public var id: String { name }
    public let name: String
    public let state: State

    public var detail: String {
        switch state {
        case .waiting: L10n.Demo.Terminal.waiting
        case .running: L10n.Demo.Terminal.running
        }
    }
}

public struct DemoWorkplace: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let path: String
    public let agentName: String
}

/// Load of the demo server, as fractions 0...1.
public struct DemoServerLoad: Hashable, Sendable {
    public let cpu: Double
    public let memory: Double
}

/// A workplace on the Server screen: where its agents' files, browser, screen and terminals live.
public struct DemoSpace: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Shared with the server: agents see what the owner sees.
        case shared
        /// A container with its own disk and limits.
        case container
        /// A separate system user.
        case user
    }

    public var id: String { name }
    public let name: String
    public let kind: Kind
    /// Names of the agents that start here.
    public let agents: [String]
    public let rows: [DemoSpaceRow]
    public let meters: [DemoMeter]
}

public struct DemoSpaceRow: Hashable, Sendable {
    /// SF Symbol shown before the label.
    public let icon: String
    public let label: String
    public let value: String
}

public struct DemoMeter: Hashable, Sendable {
    public let label: String
    /// The reading in words, e.g. "1,4 of 2 cores".
    public let value: String
    /// Share used, 0...1.
    public let fraction: Double
}

