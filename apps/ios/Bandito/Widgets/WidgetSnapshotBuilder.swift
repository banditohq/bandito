import BanditoDesign
import BanditoKit
import Foundation

// The widgets' picture of the connected servers. It reads the same rules as the screens (`InboxRules` for the count,
// `AvatarMood.crew` for the mood), so a widget never disagrees with the app.

@MainActor
enum WidgetSnapshotBuilder {
    /// The snapshot now: what the Inbox counts, and the agents of the connected servers in their team's order, the ones
    /// waiting for the person first (the picker of the widget ranks them).
    static func make(servers: [ServerModel], now: Date = Date()) -> WidgetSnapshot {
        var agents: [WidgetSnapshot.Agent] = []
        var waiting: [WidgetSnapshot.Agent] = []
        for server in servers where server.state == .connected {
            for agent in server.sortedAgents {
                let raw = server.status(of: agent.id)
                let summary = server.threadSummary(for: agent.id)
                // An agent that waits for the person shows as waiting, whatever its own status says.
                let waits = server.needsPerson(agent.id)
                let entry = WidgetSnapshot.Agent(
                    server: server.id.uuidString,
                    id: agent.id,
                    name: agent.name,
                    status: waits ? .needsYou : status(raw, paused: agent.paused),
                    mood: waits ? .needsYou : mood(AvatarMood.crew(status: raw, turnRunning: summary.turnRunning, paused: agent.paused)))
                agents.append(entry)
                if waits { waiting.append(entry) }
            }
        }
        return WidgetSnapshot(
            generatedAt: now,
            pending: InboxRules.badge(of: servers),
            agents: WidgetAgentPicker.pick(agents),
            waiting: waiting,
            waitingCount: waiting.count)
    }

    /// A paused agent is not reachable for the widget: it reads as offline (the raccoon sleeps).
    static func status(_ status: AgentStatus, paused: Bool) -> WidgetStatus {
        if paused { return .offline }
        switch status {
        case .idle: return .idle
        case .working: return .working
        case .needsYou: return .needsYou
        case .error: return .error
        case .offline: return .offline
        }
    }

    static func mood(_ mood: AvatarMood) -> WidgetMood {
        switch mood {
        case .idle: return .idle
        case .working: return .working
        case .needsYou: return .needsYou
        case .thinking: return .thinking
        case .error: return .error
        case .sleeping: return .sleeping
        }
    }
}
