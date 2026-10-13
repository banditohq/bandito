import BanditoKit
import Foundation
import Observation

/// The messages written on this iPhone that the server has not confirmed: they wait for a connection, go out in the order
/// they were written, and stay (with a way to try again) when the server refuses one. One queue for the app, kept in a
/// file (`SendQueueFile`), so a message written in a lift is not lost with the app.
///
/// The daemon takes no client id, so a send that ended without an answer is checked against the thread before it is made
/// again (`SendQueue.isDelivered`).
@MainActor
@Observable
final class ChatOutbox {
    static let shared = ChatOutbox(file: ChatOutbox.defaultFile())

    /// Counts the queue's changes; the chat watches it.
    private(set) var revision = 0
    private(set) var queue: SendQueue

    @ObservationIgnored private let file: SendQueueFile?
    @ObservationIgnored private var servers: [UUID: ServerModel] = [:]
    @ObservationIgnored private var pumping: Set<String> = []
    @ObservationIgnored private var watching: Set<UUID> = []
    @ObservationIgnored private var settling: [String: Task<Void, Never>] = [:]
    /// How long after the daemon answered a message may wait for its own event before it is let go.
    @ObservationIgnored var echoTimeout: Duration = .seconds(10)
    /// How long a send that dropped midway waits for the reconnect's events before the thread is looked at.
    @ObservationIgnored var settleDelay: Duration = .milliseconds(500)

    init(file: SendQueueFile?) {
        self.file = file
        queue = file?.load() ?? SendQueue()
    }

    static func defaultFile() -> SendQueueFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return SendQueueFile(url: base.appending(path: "Bandito/send-queue.json"))
    }

    // MARK: servers

    /// Learns the servers and sends what waits for the connected ones. Called whenever the list of servers changes.
    func attach(_ list: [ServerModel]) {
        servers = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        for server in list {
            watch(server)
            pumpAll(server)
        }
    }

    /// Watches a server's connection: when it comes back, the queue goes out.
    private func watch(_ server: ServerModel) {
        guard watching.insert(server.id).inserted else { return }
        track(server)
    }

    private func track(_ server: ServerModel) {
        withObservationTracking {
            _ = server.state
        } onChange: { [weak self, weak server] in
            Task { @MainActor in
                guard let self, let server, self.servers[server.id] === server else { return }
                self.track(server)
                if server.state == .connected { self.pumpAll(server) }
            }
        }
    }

    private func pumpAll(_ server: ServerModel) {
        guard server.state == .connected else { return }
        let agents = Set(queue.items.filter { $0.serverID == server.id }.map(\.agentID))
        for agent in agents { pump(serverID: server.id, agentID: agent) }
    }

    // MARK: queue

    func items(serverID: UUID, agentID: String) -> [QueuedSend] {
        queue.items(serverID: serverID, agentID: agentID)
    }

    @discardableResult
    func enqueue(serverID: UUID, agentID: String, text: String, attachments: [AgentAttachment] = [], viaButton: Bool = false)
        -> QueuedSend
    {
        let item = QueuedSend(
            serverID: serverID, agentID: agentID, text: text, attachments: attachments, viaButton: viaButton,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        change { $0.enqueue(item) }
        pump(serverID: serverID, agentID: agentID)
        return item
    }

    func retry(_ id: String) {
        guard let item = queue.items.first(where: { $0.id == id }) else { return }
        change { $0.retry(id) }
        pump(serverID: item.serverID, agentID: item.agentID)
    }

    func discard(_ id: String) {
        guard let item = queue.items.first(where: { $0.id == id }) else { return }
        change { $0.remove(id) }
        pump(serverID: item.serverID, agentID: item.agentID)
    }

    /// Lets go of the messages whose own event has come (the thread shows them now).
    func releaseEchoes(serverID: UUID, agentID: String, thread: AgentThread) {
        let done = queue.items(serverID: serverID, agentID: agentID).filter { SendQueue.hasEcho($0, in: thread.items) }
        guard !done.isEmpty else { return }
        change { queue in for item in done { queue.remove(item.id) } }
    }

    private func change(_ edit: (inout SendQueue) -> Void) {
        edit(&queue)
        revision &+= 1
        file?.save(queue)
    }

    // MARK: sending

    /// Starts the sender of one agent's messages, when it is not running.
    func pump(serverID: UUID, agentID: String) {
        guard let server = servers[serverID], server.state == .connected else { return }
        let key = "\(serverID)|\(agentID)"
        guard pumping.insert(key).inserted else { return }
        Task { @MainActor [weak self] in
            await self?.run(server: server, agentID: agentID)
            self?.pumping.remove(key)
            // A message queued while the last one was being answered.
            if let self, server.state == .connected, self.queue.next(serverID: serverID, agentID: agentID) != nil {
                self.pump(serverID: serverID, agentID: agentID)
            }
        }
    }

    private func run(server: ServerModel, agentID: String) async {
        while server.state == .connected, let item = queue.next(serverID: server.id, agentID: agentID) {
            if item.maybeDelivered {
                // The link dropped while it was out: the reconnect's events say whether the daemon took it.
                try? await Task.sleep(for: settleDelay)
                guard server.state == .connected else { return }
                if SendQueue.isDelivered(item, in: server.thread(for: agentID).items) {
                    change { $0.remove(item.id) }
                    continue
                }
            }
            let thread = server.thread(for: agentID)
            change { $0.begin(item.id, baseline: SendQueue.echoCount(text: item.text, in: thread.items)) }
            do {
                try await server.send(item.text, to: agentID, attachments: item.attachments, viaButton: item.viaButton)
                change { $0.sent(item.id) }
                letGo(item.id)
            } catch {
                if Self.isAmbiguousLoss(error) {
                    change { $0.interrupted(item.id) }
                    return
                }
                change { $0.refused(item.id, reason: (error as? RPCError)?.message) }
            }
        }
    }

    /// Whether `error` says the request may or may not have arrived (or could not go out now), as opposed to the server
    /// having answered with a refusal.
    nonisolated static func isAmbiguousLoss(_ error: Error) -> Bool {
        guard let rpc = error as? RPCError else { return true }
        switch rpc.code {
        case RPCError.disconnected, RPCError.timedOut, RPCError.keyRejected, RPCError.unauthorized, RPCError.rateLimited,
            RPCError.insecureTransport:
            return true
        default:
            return false
        }
    }

    /// An answered message is let go when its own event is in the thread (a second after the answer, then at the end of
    /// `echoTimeout` whatever the thread shows): an event that never comes (the daemon changed the text) must not keep a
    /// message in the queue for good.
    private func letGo(_ id: String) {
        settling[id]?.cancel()
        settling[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let first = min(self.echoTimeout, .seconds(1))
            try? await Task.sleep(for: first)
            guard !Task.isCancelled else { return }
            if let item = self.queue.items.first(where: { $0.id == id }),
                SendQueue.hasEcho(item, in: self.servers[item.serverID]?.thread(for: item.agentID).items ?? [])
            {
                self.settling[id] = nil
                self.change { $0.remove(id) }
                return
            }
            try? await Task.sleep(for: self.echoTimeout - first)
            guard !Task.isCancelled else { return }
            self.settling[id] = nil
            if self.queue.items.first(where: { $0.id == id })?.state == .sent {
                self.change { $0.remove(id) }
            }
        }
    }
}
