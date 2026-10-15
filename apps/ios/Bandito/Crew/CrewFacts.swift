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
    /// What a running turn does now and since when, nil when no turn runs.
    let working: CrewWorking?
}

/// What a running turn does now, and since when. Changes only when the activity or the start of the turn does, not at
/// every streamed token.
struct CrewWorking: Equatable {
    let activity: AgentActivity
    let since: Date

    /// Nil when no turn runs, when it has no start, when the agent is paused (it sleeps then), or when the server is not
    /// connected (a turn cut by a lost connection is never seen ending, so its timer would run forever).
    @MainActor
    init?(summary: AgentThreadState, paused: Bool, connected: Bool) {
        guard connected, !paused, summary.turnRunning, let start = summary.turnStartedAt else { return nil }
        activity = AgentActivity.current(running: summary.unfinishedTools)
        since = CrewTime.date(ms: start)
    }
}

/// What an agent waits for from the person.
enum CrewWaiting: Equatable {
    /// An approval: the title of the oldest pending one (the command the agent wants to run).
    case approval(title: String)
    /// A form the agent asked the person to fill in.
    case form
    /// A service the agent asks to connect (the Inbox's request), by its name.
    case connect(service: String)
    /// Something else that needs the person (a status "needs you" with nothing else pending): the question, as one
    /// line, nil when the agent has said nothing in text.
    case answer(question: String?)
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

/// The last message of an agent as one line for a row: Markdown marks left out, whitespace runs collapsed, nil when
/// there is no text.
enum CrewPreview {
    static func line(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = MessageBlocks.plainText(text)
            .split(whereSeparator: \.isWhitespace)
            .map(withoutHangingMarks)
            .filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The emphasis and code marks left at the ends of a word by a cut in the middle of `**bold` (the head of a message
    /// is cut at a length): taken off, so the preview shows no stray stars.
    private static func withoutHangingMarks(_ word: Substring) -> Substring {
        let marks: Set<Character> = ["*", "_", "`"]
        var word = word
        while let first = word.first, marks.contains(first) { word = word.dropFirst() }
        while let last = word.last, marks.contains(last) { word = word.dropLast() }
        return word
    }
}

/// The waiting agents of the Crew: the first `limit` are cards, the rest are counted (the "Ещё N" line).
enum CrewWaitingSplit {
    static func split<T>(_ waiting: [T], limit: Int = 2) -> (shown: [T], more: Int) {
        (Array(waiting.prefix(limit)), max(0, waiting.count - limit))
    }
}

/// What the screens say about the connection to a server, when it matters.
enum CrewConnectionNotice: Equatable {
    /// Connected: nothing to say.
    case none
    /// The first attempt is under way and there is nothing to show yet.
    case connecting
    /// Not connected, and no list to show.
    case offline
    /// Not connected, and the list shown is the saved copy of an earlier one.
    case offlineWithCache
}

extension CrewFacts {
    nonisolated static func notice(state: ConnectionState, agentsReadAt: Date?, fromCache: Bool) -> CrewConnectionNotice {
        if state == .connected { return .none }
        if fromCache { return .offlineWithCache }
        if state == .connecting, agentsReadAt == nil { return .connecting }
        return .offline
    }

    /// What an empty Inbox or Activity says instead of "nothing waits": set when no server is connected, about the first
    /// one that is not. Nil when some server is connected (the emptiness is true) or there is no server.
    @MainActor
    static func emptyNotice(servers: [ServerModel]) -> (notice: CrewConnectionNotice, server: ServerModel)? {
        guard !servers.isEmpty, !servers.contains(where: { $0.state == .connected }) else { return nil }
        for server in servers {
            let notice = notice(state: server.state, agentsReadAt: server.agentsReadAt, fromCache: server.agentsFromCache)
            if notice != .none { return (notice, server) }
        }
        return nil
    }
}

/// Builds the rows of the Crew screen from a server. Reads each agent's thread summary, never its thread.
@MainActor
enum CrewFacts {
    /// `answered`: the Inbox items the person answered from this screen, hidden at once (the daemon's event removes them
    /// later). An agent with a second approval then waits for that one.
    static func build(server: ServerModel, pinned: [String], answered: Set<String> = []) -> [CrewAgentFacts] {
        let pins = Set(pinned)
        let lead = server.leadAgentID
        let agents = CrewOrder.ordered(server.sortedAgents, id: \.id, lead: lead, pinned: pins)
        let waitingItems = waitingItems(of: server, answered: answered)
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
                waiting: waiting(waitingItems[agent.id]),
                working: CrewWorking(summary: summary, paused: agent.paused, connected: server.state == .connected))
        }
    }

    /// The time shown on a row: the newest of the thread's last event and the daemon's last message, else the last
    /// finished turn, else the last update. The same rule as the Mac's `AgentPreview.timestamp`.
    static func activity(agent: Agent, lastItemTimestamp: Int64?) -> Int64 {
        [lastItemTimestamp, agent.lastMessage?.ts].compactMap { $0 }.max() ?? agent.lastTurnAt ?? agent.updatedAt
    }

    /// The first Inbox item of each agent that is not answered yet. What waits for the person is the Inbox's own list: an
    /// agent waits exactly when it has an item there.
    static func waitingItems(of server: ServerModel, answered: Set<String> = []) -> [String: InboxItem] {
        let items = InboxRules.items(in: [server]).filter { !answered.contains($0.id) }
        return Dictionary(items.map { ($0.agentID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The approval a card answers with its two buttons: the agent's waiting item when that one is an approval. A form,
    /// a question or a connect request has no buttons on the card (the card opens the chat).
    static func approvalItem(_ item: InboxItem?) -> InboxItem? {
        guard let item, case .approval = item.kind else { return nil }
        return item
    }

    /// What the agent waits for: the kind of its Inbox item, nil when it has none (it waits for nothing).
    static func waiting(_ item: InboxItem?) -> CrewWaiting? {
        guard let item else { return nil }
        switch item.kind {
        case .approval(let row): return .approval(title: row.title)
        case .form: return .form
        case .connect(let row): return .connect(service: row.service)
        case .question: return .answer(question: item.questionLine)
        }
    }
}
