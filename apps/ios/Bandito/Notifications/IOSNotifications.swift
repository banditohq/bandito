import BanditoKit
import BanditoL10n
import Foundation
import Observation
import UserNotifications

/// The phone's notifications: the events of the servers become notices (the shared rules in `NotificationService`),
/// the notices become system notifications (`IOSNotificationSink`), and a press becomes an answer or a route into the
/// app. What is phone-only lives here: a form, a question, the risk flag, the key of each notification (the server and
/// the event's sequence number, so a repeat replaces it), and the badge.
@MainActor
@Observable
final class IOSNotifications {
    static let shared = IOSNotifications()

    /// Where a press on a notification leads the app.
    enum Route: Equatable {
        /// The agent's notification, opened from its body or its reply.
        case agent(String)
        /// A risky approval: the Inbox opens its sheet (the owner confirms with Face ID there).
        case approval(approvalID: String, agentID: String)
    }

    /// The last route a press asked for. The root view opens it and clears it.
    private(set) var route: Route?
    /// The phone is in the foreground: no notification is shown then (the person sees the change in the app).
    private(set) var isAppActive = false
    /// The user's notification choices (`IOSSettings`). Nil until the app has them: all notices are then allowed.
    var settings: IOSSettings?
    /// Where the servers come from. Set once at launch.
    var source: NotificationSource = StaticNotificationSource()

    /// The event sequence numbers each server has shown, read by the background check.
    let cursor: NotificationCursor
    private let sink: IOSNotificationSink
    private(set) var service: NotificationService!

    init() {
        cursor = NotificationCursor(defaults: .standard)
        sink = IOSNotificationSink()
        service = NotificationService(
            sink: sink,
            settings: { [weak self] in
                guard let settings = self?.settings else { return NotificationSettings() }
                return NotificationSettings(
                    needsYou: settings.notifyApprovals, finished: settings.notifyAnswers, failed: settings.notifyErrors)
            },
            windowActive: { [weak self] in self?.isAppActive ?? false },
            selectedAgentID: { nil },
            resolve: { [weak self] agentID, approvalID, decision in
                guard let server = self?.server(forAgent: agentID) else { throw AgentNotFoundError() }
                try await server.resolve(approvalID, decision, remember: false)
            },
            reply: { [weak self] agentID, text in
                guard let server = self?.server(forAgent: agentID) else { throw AgentNotFoundError() }
                try await server.send(text, to: agentID, viaButton: true)
            })
        sink.service = service
        sink.riskyNeedsFaceID = { [weak self] in self?.settings?.riskyNeedsFaceID ?? true }
        sink.onRoute = { [weak self] route in self?.route = route }
    }

    /// The server that has the agent, for an answer sent from a notification.
    func server(forAgent agentID: String) -> ServerModel? {
        source.servers.first { server in server.agents.contains { $0.id == agentID } }
    }

    /// Registers the notification categories with the system. Called once at launch; nothing is asked here.
    func start() {
        sink.start()
    }

    /// Clears the route once the root view has opened it.
    func consumeRoute() {
        route = nil
    }

    /// The app became active or inactive (scene phase). Background entry also asks for the next background check.
    func appActiveChanged(_ active: Bool) {
        isAppActive = active
        if !active { BackgroundRefresh.schedule() }
    }

    /// Feeds the servers' live events to the notifications and refreshes the badge. Called when the servers appear.
    func attach(_ servers: [ServerModel]) {
        for server in servers {
            server.onLiveEvent = { [weak self, weak server] event in
                guard let self, let server else { return }
                self.ingest(event, from: server)
            }
        }
        updateBadge()
    }

    /// One event of a server (live, or read by the background check): shows its notice when there is one. The cursor
    /// moves past every event, so a background check never repeats one.
    func ingest(_ event: Event, from server: ServerModel) {
        cursor.advance(serverID: server.id, to: event.seq)
        if case .approvalResolved(let approvalID, _, _, _) = event.body {
            service.approvalSettled(approvalID)
        }
        guard event.seq > 0, let made = Self.notice(for: event, in: server) else { return }
        guard !isViewingAgent(server: server, agent: event.agentId) else { return }
        service.handle(
            made.notice, serverID: server.id, key: Self.key(serverID: server.id, seq: event.seq), risky: made.risky)
        updateBadge()
    }

    /// Whether the person is looking at this agent's chat now. There is no chat screen yet, so this is false: the
    /// extension point for the chat (its notifications are not shown while it is open).
    func isViewingAgent(server: ServerModel, agent: String) -> Bool {
        false
    }

    /// The badge of the app icon: the number of things waiting in the Inbox.
    func updateBadge() {
        let count = InboxRules.badge(of: source.servers)
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    /// The background check (BGAppRefreshTask). Reads each server's events after its cursor and shows their notices.
    /// Best effort: iOS decides when it runs, and the task ends within `BackgroundRefresh.budget`.
    func refreshInBackground(_ task: BGAppRefreshTaskBox) async {
        BackgroundRefresh.schedule()
        let servers = source.servers
        let work = Task { @MainActor in
            for server in servers {
                if Task.isCancelled { return }
                let after = cursor.seq(for: server.id)
                guard let events = try? await source.events(after: after, serverID: server.id) else { continue }
                for event in events where event.seq > after {
                    ingest(event, from: server)
                }
            }
        }
        task.onExpire { work.cancel() }
        let timer = Task {
            try? await Task.sleep(for: BackgroundRefresh.budget)
            work.cancel()
        }
        await work.value
        timer.cancel()
        task.finish(success: !work.isCancelled)
    }

    /// The route a press on a notification of this kind leads to.
    static func routeForPress(agentID: String, approvalID: String) -> Route {
        approvalID.isEmpty ? .agent(agentID) : .approval(approvalID: approvalID, agentID: agentID)
    }

    /// The identifier of a system notification: one per server and event, so a repeat replaces the first.
    static func key(serverID: UUID, seq: Int64) -> String {
        "\(serverID.uuidString):\(seq)"
    }

    /// The Inbox row an approval's sheet opens from: the approval's own item id (`InboxRules`).
    static func inboxItemID(approvalID: String) -> String {
        "approval-\(approvalID)"
    }

    /// The notice an event makes on the phone and whether it is risky. The shared notices (approval, finished, error)
    /// come from `AgentNotice.notice(for:in:)`; a form and a question are phone-only.
    static func notice(for event: Event, in server: ServerModel) -> (notice: AgentNotice, risky: Bool)? {
        if case .approvalRequested(_, _, _, _, _, _, let reason, _) = event.body {
            guard let notice = AgentNotice.notice(for: event, in: server) else { return nil }
            return (notice, ApprovalReason.isRisky(reason))
        }
        if let notice = AgentNotice.notice(for: event, in: server) {
            return (notice, false)
        }
        let name = server.agents.first { $0.id == event.agentId }?.name ?? ""
        switch event.body {
        case .formRequested(let formID, _):
            return (.form(agentID: event.agentId, agentName: name, formID: formID), false)
        case .agentStatus(let status, _) where status == .needsYou:
            // A question is the agent's own wait: only when nothing else of the agent waits (as the Inbox lists it).
            let summary = server.threadSummary(for: event.agentId)
            guard summary.pendingApprovalRows.isEmpty, summary.pendingForms.isEmpty, summary.pendingConnects.isEmpty
            else { return nil }
            return (.question(agentID: event.agentId, agentName: name, text: summary.lastMessageHead), false)
        default:
            return nil
        }
    }
}

/// The cursor of each server's events the phone has seen (per server, in UserDefaults). Only ever moves forward.
@MainActor
final class NotificationCursor {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func seq(for serverID: UUID) -> Int64 {
        Int64(defaults.integer(forKey: Self.key(serverID)))
    }

    func advance(serverID: UUID, to seq: Int64) {
        guard seq > self.seq(for: serverID) else { return }
        defaults.set(Int(seq), forKey: Self.key(serverID))
    }

    /// A server's cursor is dropped when the server is forgotten.
    func forget(serverID: UUID) {
        defaults.removeObject(forKey: Self.key(serverID))
    }

    /// A server that has just connected for the first time: the cursor starts at the tail of its history, so the first
    /// background check shows nothing of what happened before the pairing. A server with a cursor is left alone.
    func baseline(for server: ServerModel) {
        guard seq(for: server.id) == 0, server.currentSeq > 0 else { return }
        advance(serverID: server.id, to: server.currentSeq)
    }

    private static func key(_ serverID: UUID) -> String {
        "ios.notifications.cursor.\(serverID.uuidString)"
    }
}
