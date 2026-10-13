import BanditoKit
import Foundation
import Observation

/// The messages written on this iPhone that the server has not confirmed: they wait for a connection, go out in the order
/// they were written, and stay (with a way to try again) when the server refuses one. One queue for the app, kept in a
/// file (`SendQueueFile`), so a message written in a lift is not lost with the app.
///
/// The daemon takes no client id, so a send that ended without an answer is checked against the thread before it is made
/// again (`SendQueue.isDelivered`).
/// What the outbox needs from the outside, so a test can drive it without a network or a clock.
struct ChatOutboxHooks: @unchecked Sendable {
    /// Unix ms.
    var now: @Sendable () -> Int64
    var sleep: @Sendable (Duration) async -> Void
    /// Sends one message.
    var send: @MainActor @Sendable (ServerModel, QueuedSend) async throws -> Void
    /// Reads the thread from the server, as far as the queued message needs to tell whether it is there: true when the
    /// thread was read far enough to judge (`SendQueue.echoCount` is not below the message's baseline), false when it
    /// could not be.
    var readThread: @MainActor @Sendable (ServerModel, QueuedSend) async -> Bool

    static let live = ChatOutboxHooks(
        now: { Int64(Date().timeIntervalSince1970 * 1000) },
        sleep: { try? await Task.sleep(for: $0) },
        send: { server, item in
            try await server.send(item.text, to: item.agentID, attachments: item.attachments, viaButton: item.viaButton)
        },
        readThread: { server, item in
            do {
                try await server.loadHistory(item.agentID)
                // The page may be shorter than what the baseline was counted over: read older pages until it is not.
                var pages = 0
                while SendQueue.echoCount(text: item.text, in: server.thread(for: item.agentID).items) < item.baseline,
                    server.hasMoreHistory[item.agentID] == true, pages < 20
                {
                    try await server.loadOlder(item.agentID)
                    pages += 1
                }
                return SendQueue.echoCount(text: item.text, in: server.thread(for: item.agentID).items) >= item.baseline
            } catch {
                return false
            }
        })
}

/// How a failed send is to be read.
enum ChatSendOutcome: Equatable {
    /// It may or may not have arrived (the link dropped, no answer in time).
    case lost
    /// The server limits the rate; `retryAfter` is its own word in ms, when it gave one.
    case rateLimited(retryAfter: Int64?)
    /// This device may not send (the key is not accepted, or the link is not safe): nothing helps but the person.
    case notAllowed(QueuedSend.Failure)
    /// The server answered with a refusal.
    case refused(String?)

    static func classify(_ error: Error) -> ChatSendOutcome {
        guard let rpc = error as? RPCError else { return .lost }
        switch rpc.code {
        case RPCError.disconnected, RPCError.timedOut:
            return .lost
        case RPCError.keyRejected, RPCError.unauthorized:
            return .notAllowed(.key)
        case RPCError.insecureTransport:
            return .notAllowed(.insecure)
        case RPCError.rateLimited:
            var after: Int64?
            if case .number(let seconds)? = rpc.data?["retry_after"] { after = Int64(seconds * 1000) }
            return .rateLimited(retryAfter: after)
        default:
            return .refused(rpc.message)
        }
    }
}

@MainActor
@Observable
final class ChatOutbox {
    static let shared = ChatOutbox(file: ChatOutbox.defaultFile())

    /// Counts the queue's changes; the chat watches it.
    private(set) var revision = 0
    private(set) var queue: SendQueue

    @ObservationIgnored private let file: SendQueueFile?
    @ObservationIgnored private let hooks: ChatOutboxHooks
    @ObservationIgnored private var servers: [UUID: ServerModel] = [:]
    @ObservationIgnored private var pumping: Set<String> = []
    /// The server models being watched, by id: a model made again for the same id is watched again.
    @ObservationIgnored private var watching: [UUID: ObjectIdentifier] = [:]
    @ObservationIgnored private var settling: [String: Task<Void, Never>] = [:]
    /// How long after the daemon answered a message may wait for its own event before it is let go.
    @ObservationIgnored var echoTimeout: Duration = .seconds(10)

    init(file: SendQueueFile?, hooks: ChatOutboxHooks = .live) {
        self.file = file
        self.hooks = hooks
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
        servers = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for server in servers.values {
            watch(server)
            pumpAll(server)
        }
    }

    /// Watches a server's connection: when it comes back, the queue goes out.
    private func watch(_ server: ServerModel) {
        guard watching[server.id] != ObjectIdentifier(server) else { return }
        watching[server.id] = ObjectIdentifier(server)
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
            createdAt: hooks.now())
        change { $0.enqueue(item) }
        pump(serverID: serverID, agentID: agentID)
        return item
    }

    /// Drops everything written to a server that is forgotten.
    func forget(serverID: UUID) {
        let mine = queue.items.filter { $0.serverID == serverID }.map(\.id)
        guard !mine.isEmpty else { return }
        change { queue in for id in mine { queue.remove(id) } }
    }

    /// The person tries a refused message again, or sends an uncertain one once more.
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
        // A message with the same text was waiting for this echo.
        pump(serverID: serverID, agentID: agentID)
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
            if let self, server.state == .connected, self.queue.next(serverID: serverID, agentID: agentID, now: self.hooks.now()) != nil {
                self.pump(serverID: serverID, agentID: agentID)
            }
        }
    }

    private func run(server: ServerModel, agentID: String) async {
        while server.state == .connected {
            // A message under a wait (a rate limit, a lost answer) is waited for.
            if let wait = queue.delay(serverID: server.id, agentID: agentID, now: hooks.now()), wait > 0 {
                await hooks.sleep(.milliseconds(wait))
                continue
            }
            guard let item = queue.next(serverID: server.id, agentID: agentID, now: hooks.now()) else { return }
            if item.maybeDelivered {
                // The link dropped while it was out. Whether the daemon took it is read from the daemon's own record of the
                // thread, never guessed from a timer; a thread that cannot be read leaves the decision to the person.
                guard await hooks.readThread(server, item) else {
                    change { $0.uncertain(item.id) }
                    return
                }
                if SendQueue.isDelivered(item, in: server.thread(for: agentID).items) {
                    change { $0.remove(item.id) }
                    continue
                }
            }
            let thread = server.thread(for: agentID)
            change { $0.begin(item.id, baseline: SendQueue.echoCount(text: item.text, in: thread.items)) }
            do {
                try await hooks.send(server, item)
                change { $0.sent(item.id) }
                letGo(item.id)
            } catch {
                switch ChatSendOutcome.classify(error) {
                case .lost:
                    change { $0.interrupted(item.id, now: hooks.now()) }
                case .rateLimited(let after):
                    change { $0.limited(item.id, now: hooks.now(), retryAfter: after) }
                case .notAllowed(let kind):
                    change { $0.refused(item.id, reason: nil, kind: kind) }
                case .refused(let message):
                    change { $0.refused(item.id, reason: message) }
                }
            }
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
            await self.hooks.sleep(first)
            guard !Task.isCancelled else { return }
            if let item = self.queue.items.first(where: { $0.id == id }),
                SendQueue.hasEcho(item, in: self.servers[item.serverID]?.thread(for: item.agentID).items ?? [])
            {
                self.settling[id] = nil
                self.change { $0.remove(id) }
                self.pump(serverID: item.serverID, agentID: item.agentID)
                return
            }
            await self.hooks.sleep(self.echoTimeout - first)
            guard !Task.isCancelled else { return }
            self.settling[id] = nil
            if let item = self.queue.items.first(where: { $0.id == id }), item.state == .sent {
                self.change { $0.remove(id) }
                self.pump(serverID: item.serverID, agentID: item.agentID)
            }
        }
    }
}
