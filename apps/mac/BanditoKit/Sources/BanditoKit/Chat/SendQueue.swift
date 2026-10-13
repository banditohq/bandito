import Foundation

/// A message the person sent that has not reached the server yet, or whose arrival is not confirmed. The iPhone keeps
/// these while there is no connection ("Waiting for connection") and sends them in order when it is back.
///
/// The daemon has no client message id (`agents.send` takes the text, the files and the reply target), so a send that
/// ended without an answer (the link dropped after the request went out) cannot be told from one that never left. The
/// queue records how many messages with this text the thread showed when the attempt began (`baseline`); once the
/// thread shows more, the daemon did take it, and the message is not sent again (`SendQueue.isDelivered`).
public struct QueuedSend: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// Waits for a connection, or for the message before it.
        case waiting
        /// The request is out.
        case sending
        /// The daemon answered; the person's message has not come back as an event yet.
        case sent
        /// The daemon refused it (or it can never go out): the person decides.
        case failed
    }

    public var id: String
    public var serverID: UUID
    public var agentID: String
    public var text: String
    public var attachments: [AgentAttachment]
    public var viaButton: Bool
    /// Unix milliseconds, on this device.
    public var createdAt: Int64
    public var state: State
    /// Messages with this text in the thread when the attempt began.
    public var baseline: Int
    /// An attempt ended without an answer: the daemon may have the message.
    public var maybeDelivered: Bool
    /// Why it failed, for a person to read (the server's words, or empty).
    public var failure: String?

    public init(
        id: String = UUID().uuidString, serverID: UUID, agentID: String, text: String,
        attachments: [AgentAttachment] = [], viaButton: Bool = false, createdAt: Int64, state: State = .waiting,
        baseline: Int = 0, maybeDelivered: Bool = false, failure: String? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.agentID = agentID
        self.text = text
        self.attachments = attachments
        self.viaButton = viaButton
        self.createdAt = createdAt
        self.state = state
        self.baseline = baseline
        self.maybeDelivered = maybeDelivered
        self.failure = failure
    }
}

/// The queue of unsent messages of one device: pure state, kept as a file by the app. Messages of one agent leave one
/// at a time, in the order they were written.
public struct SendQueue: Codable, Equatable, Sendable {
    public private(set) var items: [QueuedSend] = []

    public init(items: [QueuedSend] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }

    public func items(serverID: UUID, agentID: String) -> [QueuedSend] {
        items.filter { $0.serverID == serverID && $0.agentID == agentID }
    }

    public mutating func enqueue(_ item: QueuedSend) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
    }

    /// The message to send next for this agent: the oldest, when nothing of the agent is out or refused before it. A
    /// refused message blocks the ones after it, so the order the person wrote them in is never changed.
    public func next(serverID: UUID, agentID: String) -> QueuedSend? {
        for item in items where item.serverID == serverID && item.agentID == agentID {
            switch item.state {
            case .waiting: return item
            case .sending, .failed: return nil
            case .sent: continue
            }
        }
        return nil
    }

    /// The request goes out. `baseline` is the count of same-text messages the thread shows now.
    public mutating func begin(_ id: String, baseline: Int) {
        update(id) {
            $0.state = .sending
            $0.baseline = baseline
        }
    }

    /// The daemon answered.
    public mutating func sent(_ id: String) {
        update(id) {
            $0.state = .sent
            $0.maybeDelivered = false
        }
    }

    /// The attempt ended without an answer (the link dropped): back to waiting, and the daemon may have the message.
    public mutating func interrupted(_ id: String) {
        update(id) {
            $0.state = .waiting
            $0.maybeDelivered = true
        }
    }

    /// The daemon refused the message.
    public mutating func refused(_ id: String, reason: String?) {
        update(id) {
            $0.state = .failed
            $0.failure = reason
            $0.maybeDelivered = false
        }
    }

    /// The person tries a refused message again.
    public mutating func retry(_ id: String) {
        update(id) {
            $0.state = .waiting
            $0.failure = nil
        }
    }

    public mutating func remove(_ id: String) {
        items.removeAll { $0.id == id }
    }

    /// What a start of the app keeps: a message that was out is waiting again and may have arrived; one the daemon had
    /// answered is taken as delivered.
    public mutating func restoredAfterLaunch() {
        items.removeAll { $0.state == .sent }
        for index in items.indices where items[index].state == .sending {
            items[index].state = .waiting
            items[index].maybeDelivered = true
        }
    }

    private mutating func update(_ id: String, _ change: (inout QueuedSend) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: delivery

    /// How many messages of the person with this text the thread shows.
    public static func echoCount(text: String, in items: [ThreadItem]) -> Int {
        items.reduce(0) { count, item in
            if case .user(_, let sent, let source, _, _, _) = item, source == .user, sent == text { return count + 1 }
            return count
        }
    }

    /// The daemon has the message: the thread shows more messages with its text than when the attempt began.
    public static func isDelivered(_ item: QueuedSend, in items: [ThreadItem]) -> Bool {
        echoCount(text: item.text, in: items) > item.baseline
    }

    /// Whether the person's message has come back as an event after the daemon answered.
    public static func hasEcho(_ item: QueuedSend, in items: [ThreadItem]) -> Bool {
        item.state == .sent && isDelivered(item, in: items)
    }
}

/// Where the queue is kept between launches: one JSON file, left out of backups by the app.
public struct SendQueueFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> SendQueue {
        guard let data = try? Data(contentsOf: url), var queue = try? JSONDecoder().decode(SendQueue.self, from: data)
        else { return SendQueue() }
        queue.restoredAfterLaunch()
        return queue
    }

    public func save(_ queue: SendQueue) {
        if queue.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
