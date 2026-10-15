import BanditoKit
import Foundation

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
            })
    }
}

@MainActor
final class ShareImporter {
    static let shared = ShareImporter()

    private let inbox: ShareInbox?
    private var environment: ShareImporterEnvironment?
    private var running: Task<Void, Never>?
    /// Where a task went once it was queued, until its link opens the chat (once).
    private var queued: [UUID: (server: UUID, agent: String)] = [:]

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

    /// The chat a `bandito://share/<id>` link leads to: the agent of the task, whether it is still waiting in the inbox
    /// or was queued already. Nil once the link was used, or for a task that is gone. Call before `drain`.
    func target(of id: UUID) -> (server: UUID, agent: String)? {
        if let done = queued.removeValue(forKey: id) { return done }
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
        for task in inbox.pending() {
            if Task.isCancelled { return }
            guard let serverID = UUID(uuidString: task.serverID) else {
                inbox.remove(id: task.id)
                continue
            }
            switch ShareImportRule.decide(task, facts: environment.facts(serverID, task.agentID)) {
            case .drop:
                inbox.remove(id: task.id)
            case .wait:
                continue
            case .send:
                guard let attachments = await upload(task, serverID: serverID, inbox: inbox, environment: environment)
                else { continue }
                if attachments.isEmpty, task.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Its pictures were unreadable and there is no text: nothing is left to send.
                    inbox.remove(id: task.id)
                    continue
                }
                environment.enqueue(serverID, task.agentID, task.text, attachments)
                queued[task.id] = (serverID, task.agentID)
                if queued.count > 20, let oldest = queued.keys.first { queued.removeValue(forKey: oldest) }
                // Only now, with the message in the outbox, the task is let go.
                inbox.remove(id: task.id)
            }
        }
    }

    /// The task's pictures, one after another, on the server; nil when one failed (the task stays for the next time).
    private func upload(
        _ task: SharedTask, serverID: UUID, inbox: ShareInbox, environment: ShareImporterEnvironment
    ) async -> [AgentAttachment]? {
        var attachments: [AgentAttachment] = []
        let stamp = Int(task.createdAt.timeIntervalSince1970)
        for (index, name) in task.images.enumerated() {
            // A picture that cannot be read is left out; the rest go.
            guard let data = inbox.imageData(task: task, name: name) else { continue }
            do {
                attachments.append(
                    try await environment.upload(serverID, task.agentID, data, "photo-\(stamp)-\(index + 1).jpg"))
            } catch {
                return nil
            }
        }
        return attachments
    }
}
