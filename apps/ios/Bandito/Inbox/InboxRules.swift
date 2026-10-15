import BanditoDesign
import BanditoKit
import Foundation

// What the Inbox lists: everything that waits for the person on every connected server. Pure rules over the servers'
// summaries (`AgentThreadState`), so the list reads what changed, never a whole thread.

/// One thing that waits for the person. A value: the list rebuilds a row only when one of its facts changed.
struct InboxItem: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A request to run a command (or a tool): allow or deny.
        case approval(ApprovalRow)
        /// A form the agent asked the person to fill in.
        case form(FormRow)
        /// A service the agent asks to connect. The phone can only decline it for now.
        case connect(ConnectRow)
        /// The agent waits for an answer: its last message, and the buttons it offers under it.
        case question(text: String?, buttons: [QuickReplyButton])
    }

    /// Unique over the servers: the request's own id (the question's: its agent and the time of its last message).
    let id: String
    let serverID: UUID
    let serverName: String
    let agentID: String
    let agentName: String
    let look: CrewLook
    let mood: AvatarMood
    let kind: Kind
    /// When the request was made (Unix ms); 0 when the daemon did not say.
    let ts: Int64
    /// A question's last message as one plain line (Markdown left out), made once with the item; nil for the others.
    var questionLine: String? = nil

    /// A risky approval: the daemon's reason marks it (`ApprovalReason.isRisky`). Nothing else is risky.
    var isRisky: Bool {
        if case .approval(let row) = kind { return ApprovalReason.isRisky(row.reason) }
        return false
    }

    /// Whether a swipe to the right (or Approve) allows it at once. A risky one is never allowed by a swipe: its sheet opens.
    var canAllow: Bool {
        if case .approval = kind { return true }
        return false
    }

    /// Whether a swipe to the left (or Deny) refuses it: an approval, a form (rejected without an answer) or a connect.
    var canDeny: Bool {
        switch kind {
        case .approval, .form, .connect: true
        case .question: false
        }
    }
}

/// A group of the Inbox: one server's items, or all of them when there is one server.
struct InboxSection: Identifiable, Equatable {
    /// The server's id; nil for the single flat group.
    let id: UUID?
    /// The server's name as the group header; nil for the flat group.
    let title: String?
    let items: [InboxItem]
}

@MainActor
enum InboxRules {
    /// The items of the connected servers, newest first (an item without a time goes last).
    static func items(in servers: [ServerModel]) -> [InboxItem] {
        let all = servers.filter { $0.state == .connected }.flatMap { items(of: $0) }
        return all.enumerated()
            .sorted { a, b in
                if a.element.ts != b.element.ts { return a.element.ts > b.element.ts }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// The items of one server, in the order of its team (the sort by time is `items(in:)`).
    static func items(of server: ServerModel) -> [InboxItem] {
        var found: [InboxItem] = []
        for agent in server.sortedAgents {
            let summary = server.threadSummary(for: agent.id)
            let status = server.status(of: agent.id)
            let mood = AvatarMood.crew(status: status, turnRunning: summary.turnRunning, paused: agent.paused)
            let look = CrewLook(agent: agent)
            func add(_ id: String, _ ts: Int64?, _ kind: InboxItem.Kind, questionLine: String? = nil) {
                found.append(
                    InboxItem(
                        id: id, serverID: server.id, serverName: server.config.name, agentID: agent.id,
                        agentName: agent.name, look: look, mood: mood, kind: kind, ts: ts ?? 0,
                        questionLine: questionLine))
            }
            for row in summary.pendingApprovalRows {
                add("approval-\(row.approvalId)", row.ts, .approval(row))
            }
            for row in summary.pendingForms {
                add("form-\(row.formId)", row.ts, .form(row))
            }
            for row in summary.pendingConnects {
                add("connect-\(row.requestId)", row.ts, .connect(row))
            }
            // A question is the agent's own wait: only when nothing else of the agent waits, as the team's "waiting for
            // you" line says it.
            if status == .needsYou, summary.pendingApprovalRows.isEmpty, summary.pendingForms.isEmpty,
                summary.pendingConnects.isEmpty
            {
                let when = summary.lastItemTimestamp ?? 0
                add(
                    "question-\(agent.id)-\(when)", when,
                    .question(text: summary.lastMessageHead, buttons: summary.quickReplies?.buttons ?? []),
                    questionLine: CrewPreview.line(summary.lastMessageHead ?? agent.lastMessage?.text))
            }
        }
        return found
    }

    /// The item a notice's route names, once it is in the list. Nil while it is not: a cold start has no list yet, so the
    /// route must wait for its item rather than be dropped.
    static func focusedItem(_ id: String, in items: [InboxItem]) -> InboxItem? {
        items.first { $0.id == id }
    }

    /// The number on the Inbox tab: every item the list shows.
    static func badge(of servers: [ServerModel]) -> Int {
        items(in: servers).count
    }

    /// The groups of the list: one flat group with one server, else one group per server in the order of `servers`
    /// (a server with nothing waiting has no group).
    static func sections(_ items: [InboxItem], servers: [UUID], grouped: Bool) -> [InboxSection] {
        guard grouped else {
            return items.isEmpty ? [] : [InboxSection(id: nil, title: nil, items: items)]
        }
        return servers.compactMap { serverID in
            let mine = items.filter { $0.serverID == serverID }
            guard let first = mine.first else { return nil }
            return InboxSection(id: serverID, title: first.serverName, items: mine)
        }
    }
}

/// Counts the bodies of the Inbox rows that were evaluated: the speed test reads it. A new event in an agent's chat
/// changes no row's facts, so it builds at most two rows (the same counter pattern as `CrewCounters`).
@MainActor
enum InboxCounters {
    static var rowBodies = 0

    /// Called from a row's body: one more evaluation.
    static func rowBodyRan() {
        rowBodies += 1
    }
}
