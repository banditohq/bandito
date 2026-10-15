import BanditoKit
import BanditoL10n
import Foundation
import UserNotifications

// Takes what the share extension left in the App Group and sends it as the person's own messages: pictures are uploaded
// to the agent, then the message goes into `ChatOutbox` (which keeps it until the server is online). A task is removed
// only after it is in the outbox; a task that cannot be sent yet stays for the next time.

/// What the importer needs to know about the server a task names.
struct ShareServerFacts: Equatable {
    var connected: Bool
    /// The agents were read from the server, so a missing agent is really gone.
    var agentsKnown: Bool
    var hasAgent: Bool
}

/// What became of a task that was dropped, for the toast.
struct ShareNotice: Equatable {
    enum Kind: Equatable {
        /// The agent is not on the server any more.
        case agentGone
        /// The pictures could not be uploaded, five times.
        case failedForGood
    }

    let kind: Kind
    let agentName: String

    var text: String {
        switch kind {
        case .agentGone: L10n.Ios.Share.agentGone(name: agentName)
        case .failedForGood: L10n.Ios.Share.failedForGood(name: agentName)
        }
    }
}

enum ShareImportDecision: Equatable {
    /// Nothing can come of this task (no text and no pictures, or the server or agent is gone): delete it.
    case drop
    /// It has pictures and the server is not connected: keep it for later.
    case wait
    /// Upload the pictures, then queue the message.
    case send
}

enum ShareImportRule {
    /// - Parameter facts: nil when the server is not in the app.
    static func decide(_ task: SharedTask, facts: ShareServerFacts?) -> ShareImportDecision {
        let hasText = !task.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !task.images.isEmpty else { return .drop }
        guard let facts else { return .drop }
        if facts.connected, facts.agentsKnown, !facts.hasAgent { return .drop }
        if !task.images.isEmpty, !facts.connected { return .wait }
        return .send
    }
}

/// How the importer reaches the app: the servers, the upload and the outbox. Closures, so a test needs no network.
struct ShareImporterEnvironment {
    /// False until the saved servers are read: a task is never judged against a list that is not loaded yet.
    var serversLoaded: @MainActor () -> Bool
    var facts: @MainActor (_ serverID: UUID, _ agentID: String) -> ShareServerFacts?
    var upload: @MainActor (_ serverID: UUID, _ agentID: String, _ data: Data, _ name: String) async throws -> AgentAttachment
    var enqueue: @MainActor (_ serverID: UUID, _ agentID: String, _ text: String, _ attachments: [AgentAttachment]) -> Void
    /// Asks the server for its agents again and returns when the list is updated.
    var refreshAgents: @MainActor (_ serverID: UUID) async -> Void = { _ in }
    /// Takes down the reminder the share sheet left for the task (`share-<id>`): delivered or still waiting.
    var clearReminder: @MainActor (_ taskID: UUID) -> Void = { _ in }

    @MainActor
    static func live(session: ServerSession) -> ShareImporterEnvironment {
        func server(_ id: UUID) -> ServerModel? { session.current.first { $0.id == id } }
        return ShareImporterEnvironment(
            serversLoaded: { !session.current.isEmpty },
            facts: { id, agentID in
                guard let model = server(id) else { return nil }
                return ShareServerFacts(
                    connected: model.state == .connected, agentsKnown: model.agentsReadAt != nil,
                    hasAgent: model.agents.contains { $0.id == agentID })
            },
            upload: { id, agentID, data, name in
                guard let model = server(id) else { throw CancellationError() }
                return try await model.uploadAttachment(data, name: name, agentId: agentID)
            },
            enqueue: { id, agentID, text, attachments in
                ChatOutbox.shared.enqueue(serverID: id, agentID: agentID, text: text, attachments: attachments)
            },
            refreshAgents: { id in await server(id)?.refreshAgentsNow() },
            clearReminder: { taskID in
                let identifier = ShareReminder.identifier(for: taskID)
                let center = UNUserNotificationCenter.current()
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
            })
    }
}

@MainActor
final class ShareImporter {
    static let shared = ShareImporter()

    private let inbox: ShareInbox?
    private var environment: ShareImporterEnvironment?
    private var running: Task<Void, Never>?
    /// Where a task went once it was queued, until its link opens the chat (once). `queuedOrder` is the order they came
    /// in, so that the oldest goes first when there are more than `queuedLimit`.
    private var queued: [UUID: (server: UUID, agent: String)] = [:]
    private var queuedOrder: [UUID] = []
    private static let queuedLimit = 20

    /// Told when a task was dropped for a reason the person should hear (the root view shows a toast).
    var onNotice: ((ShareNotice) -> Void)?

    init(inbox: ShareInbox? = ShareInbox.appGroup(), environment: ShareImporterEnvironment? = nil) {
        self.inbox = inbox
        self.environment = environment
    }

    func attach(_ environment: ShareImporterEnvironment) {
        self.environment = environment
    }

    /// Once at launch: tasks nobody took for a week are dropped.
    func cleanUp() {
        inbox?.removeOlder()
    }

    /// The chat a `bandito://share/<id>` link leads to: the agent of the task, whether it was queued by now or still waits
    /// in the inbox. Nil for a task that was dropped or is gone, and once the link was used. Call after `drain`: a task
    /// that was dropped must not open a chat.
    func target(of id: UUID) -> (server: UUID, agent: String)? {
        if let done = queued.removeValue(forKey: id) {
            queuedOrder.removeAll { $0 == id }
            return done
        }
        guard let task = inbox?.task(id: id), let server = UUID(uuidString: task.serverID) else { return nil }
        return (server, task.agentID)
    }

    /// Sends every waiting task, the oldest first. A call while another runs waits for it and then runs again, so no
    /// task saved in between is missed, and no task is sent twice.
    func drain() async {
        while let running { await running.value }
        let pass = Task { @MainActor [self] in
            await self.pass()
            self.running = nil
        }
        running = pass
        await pass.value
    }

    private func pass() async {
        guard let inbox, let environment, environment.serversLoaded() else { return }
        var refreshed: Set<UUID> = []
        for task in inbox.pending() {
            if Task.isCancelled { return }
            guard let serverID = UUID(uuidString: task.serverID) else {
                finish(task, inbox: inbox, environment: environment)
                continue
            }
            var facts = environment.facts(serverID, task.agentID)
            var decision = ShareImportRule.decide(task, facts: facts)
            // An agent that is not in the list may only be missing from an old list: the list is read again, once for
            // each server, before the task is let go.
            if decision == .drop, Self.agentLooksGone(task, facts), refreshed.insert(serverID).inserted {
                await environment.refreshAgents(serverID)
                facts = environment.facts(serverID, task.agentID)
                decision = ShareImportRule.decide(task, facts: facts)
            }
            switch decision {
            case .drop:
                if Self.agentLooksGone(task, facts) { onNotice?(ShareNotice(kind: .agentGone, agentName: task.displayName)) }
                finish(task, inbox: inbox, environment: environment)
            case .wait:
                continue
            case .send:
                await send(task, serverID: serverID, inbox: inbox, environment: environment)
            }
        }
    }

    /// True when the server is connected, its agents are read, and this one is not among them (for a task with content).
    private static func agentLooksGone(_ task: SharedTask, _ facts: ShareServerFacts?) -> Bool {
        guard let facts, facts.connected, facts.agentsKnown, !facts.hasAgent else { return false }
        return !task.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !task.images.isEmpty
    }

    /// The task is over (sent or dropped): its folder and its reminder go.
    private func finish(_ task: SharedTask, inbox: ShareInbox, environment: ShareImporterEnvironment) {
        inbox.remove(id: task.id)
        environment.clearReminder(task.id)
    }

    private func send(
        _ task: SharedTask, serverID: UUID, inbox: ShareInbox, environment: ShareImporterEnvironment
    ) async {
        var task = task
        var attachments: [AgentAttachment] = []
        let stamp = Int(task.createdAt.timeIntervalSince1970)
        for (index, name) in task.images.enumerated() {
            if let done = task.uploaded[name] {
                attachments.append(AgentAttachment(path: done.path, name: done.name, size: done.size, mime: done.mime))
                continue
            }
            // A picture that cannot be read is left out; the rest go.
            guard let data = inbox.imageData(task: task, name: name) else { continue }
            do {
                let saved = try await environment.upload(serverID, task.agentID, data, "photo-\(stamp)-\(index + 1).jpg")
                task.uploaded[name] = SharedUpload(path: saved.path, name: saved.name, size: saved.size, mime: saved.mime)
                inbox.update(task)
                attachments.append(saved)
            } catch {
                // The server is connected (a task with pictures waits otherwise): this counts as a failed try.
                task.attempts += 1
                if task.attempts >= SharedTask.maxAttempts {
                    onNotice?(ShareNotice(kind: .failedForGood, agentName: task.displayName))
                    finish(task, inbox: inbox, environment: environment)
                } else {
                    inbox.update(task)
                }
                return
            }
        }
        if attachments.isEmpty, task.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Its pictures were unreadable and there is no text: nothing is left to send.
            finish(task, inbox: inbox, environment: environment)
            return
        }
        environment.enqueue(serverID, task.agentID, task.text, attachments)
        queued[task.id] = (serverID, task.agentID)
        queuedOrder.append(task.id)
        while queuedOrder.count > Self.queuedLimit {
            queued.removeValue(forKey: queuedOrder.removeFirst())
        }
        // Only now, with the message in the outbox, the task is let go.
        finish(task, inbox: inbox, environment: environment)
    }
}
