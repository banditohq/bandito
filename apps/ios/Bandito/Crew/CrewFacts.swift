import BanditoDesign
import BanditoKit
import Foundation
import SwiftUI

// What the Crew screen shows of each agent. The rows are `Equatable` over these facts: a row is built again only when
// one of them changes, so a streamed token (which changes none of them once the preview is full) rebuilds no row.

/// One agent as the Crew screen shows it.
struct CrewAgentFacts: Equatable, Identifiable {
    let id: String
    let name: String
    let role: String
    let status: AgentStatus
    let mood: AvatarMood
    let look: CrewLook
    /// The last message as one line, nil when there is none yet.
    let preview: String?
    /// When the agent last did something (Unix ms).
    let activityMs: Int64
    /// Replies the person has not read yet.
    let unread: Int
    let isLead: Bool
    let isPinned: Bool
    let isPaused: Bool
    /// What the agent waits for from the person, nil when it waits for nothing.
    let waiting: CrewWaiting?
}

/// What an agent waits for from the person.
enum CrewWaiting: Equatable {
    /// An approval: the title of the oldest pending one (the command the agent wants to run).
    case approval(title: String)
    /// A form the agent asked the person to fill in.
    case form
    /// Something else that needs the person (a status "needs you" with nothing else pending).
    case answer
}

/// The look of an agent's avatar on iPhone: the palette color or a custom `#RRGGBB`, and the face. Read from the
/// agent's saved avatar, with the automatic color and face of its name where nothing is saved.
struct CrewLook: Equatable {
    let color: AvatarColor
    let face: AvatarFace
    /// A custom tile color as `#RRGGBB`, nil for a palette color.
    let customHex: String?

    init(color: AvatarColor, face: AvatarFace, customHex: String?) {
        self.color = color
        self.face = face
        self.customHex = customHex
    }

    init(agent: Agent) {
        let spec = agent.avatar
        let resolved = AvatarResolver.resolve(
            name: agent.name,
            color: spec.flatMap { AvatarColor(rawValue: $0.color) },
            face: spec.flatMap { AvatarFace(rawValue: $0.face) } ?? .auto)
        color = resolved.color
        face = resolved.face
        customHex = spec.flatMap { AvatarHex.normalized($0.color) }
    }

    /// The tile color: the custom one when it is valid, else the palette's.
    var tint: Color {
        customHex.flatMap(AvatarHex.value).map { Color(rgb: $0) } ?? color.color
    }
}

extension Color {
    /// sRGB color from a 0xRRGGBB value.
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1)
    }
}

extension AvatarMood {
    /// The mood of an agent on iPhone. Like the Mac's `AvatarMood.make`, but without a stream to tell apart: a running
    /// turn of an idle agent reads as thinking. A paused agent sleeps whatever it was doing.
    static func crew(status: AgentStatus, turnRunning: Bool, paused: Bool) -> AvatarMood {
        if paused { return .sleeping }
        switch status {
        case .needsYou: return .needsYou
        case .error: return .error
        case .offline: return .sleeping
        case .working: return .working
        case .idle: return turnRunning ? .thinking : .idle
        }
    }
}

/// The order of the team: the lead first, then the pinned agents, then the rest in the order they came in.
enum CrewOrder {
    static func ordered<T>(_ items: [T], id: (T) -> String, lead: String?, pinned: Set<String>) -> [T] {
        func rank(_ item: T) -> Int {
            let itemID = id(item)
            if itemID == lead { return 0 }
            return pinned.contains(itemID) ? 1 : 2
        }
        return items.enumerated()
            .sorted { a, b in
                let (ra, rb) = (rank(a.element), rank(b.element))
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }
}

/// The pinned agents of one server, kept on this iPhone only (`UserDefaults`).
enum CrewPins {
    static func key(_ serverID: UUID) -> String { "crew.pinned.\(serverID.uuidString)" }

    static func load(_ serverID: UUID, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key(serverID)) ?? []
    }

    static func save(_ ids: [String], serverID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(ids, forKey: key(serverID))
    }

    /// The list with `id` added when it is not in it, removed when it is.
    static func toggled(_ id: String, in ids: [String]) -> [String] {
        ids.contains(id) ? ids.filter { $0 != id } : ids + [id]
    }
}

/// The last message of an agent as one line for a row: whitespace runs collapsed, nil when there is no text.
enum CrewPreview {
    static func line(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

/// Builds the rows of the Crew screen from a server. Reads each agent's thread summary, never its thread.
@MainActor
enum CrewFacts {
    static func build(server: ServerModel, pinned: [String]) -> [CrewAgentFacts] {
        let pins = Set(pinned)
        let lead = server.leadAgentID
        let agents = CrewOrder.ordered(server.sortedAgents, id: \.id, lead: lead, pinned: pins)
        return agents.map { agent in
            let summary = server.threadSummary(for: agent.id)
            let status = server.status(of: agent.id)
            return CrewAgentFacts(
                id: agent.id,
                name: agent.name,
                role: agent.role,
                status: status,
                mood: AvatarMood.crew(status: status, turnRunning: summary.turnRunning, paused: agent.paused),
                look: CrewLook(agent: agent),
                preview: CrewPreview.line(summary.lastMessageHead ?? agent.lastMessage?.text),
                activityMs: activity(agent: agent, lastItemTimestamp: summary.lastItemTimestamp),
                unread: summary.unreadCount,
                isLead: agent.id == lead,
                isPinned: pins.contains(agent.id),
                isPaused: agent.paused,
                waiting: waiting(needsPerson: server.needsPerson(agent.id), summary: summary))
        }
    }

    /// The time shown on a row: the newest of the thread's last event and the daemon's last message, else the last
    /// finished turn, else the last update. The same rule as the Mac's `AgentPreview.timestamp`.
    static func activity(agent: Agent, lastItemTimestamp: Int64?) -> Int64 {
        [lastItemTimestamp, agent.lastMessage?.ts].compactMap { $0 }.max() ?? agent.lastTurnAt ?? agent.updatedAt
    }

    /// What the agent waits for, from the thread's summary; nil when nothing waits for the person.
    static func waiting(needsPerson: Bool, summary: AgentThreadState) -> CrewWaiting? {
        guard needsPerson else { return nil }
        if let title = summary.firstPendingApprovalTitle { return .approval(title: title) }
        if !summary.pendingForms.isEmpty { return .form }
        return .answer
    }
}
