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
        /// The connection dropped and the thread could not be read to see whether the daemon took it: not sent again until
        /// the person says so (send again, or remove).
        case uncertain
    }

    /// Why a message is `failed`, for the line under it.
    public enum Failure: String, Codable, Sendable {
        /// The server answered with a refusal.
        case refused
        /// The server does not accept this device's key (or the connection may not carry it).
        case key
        case insecure
        /// Several tries ended without an answer.
        case gaveUp
    }

    public var id: String
    public var serverID: UUID
    public var agentID: String
    public var text: String
    public var attachments: [AgentAttachment]
    public var viaButton: Bool
    /// The `seq` of the message this one answers (a reply), when the person chose Reply.
    public var replyTo: Int64?
    /// Unix milliseconds, on this device.
    public var createdAt: Int64
    public var state: State
    /// Messages with this text in the thread when the attempt began.
    public var baseline: Int
    /// An attempt ended without an answer: the daemon may have the message.
    public var maybeDelivered: Bool
    /// Why it failed, for a person to read (the server's words, or empty).
    public var failure: String?
    public var failureKind: Failure?
    /// Sends that ended without an answer, since the person last tried.
    public var attempts: Int
    /// Not before this time (Unix ms, this device): the wait after a rate limit or a lost answer.
    public var retryAt: Int64?

    public init(
        id: String = UUID().uuidString, serverID: UUID, agentID: String, text: String,
        attachments: [AgentAttachment] = [], viaButton: Bool = false, createdAt: Int64, state: State = .waiting,
        baseline: Int = 0, maybeDelivered: Bool = false, failure: String? = nil, failureKind: Failure? = nil,
        attempts: Int = 0, retryAt: Int64? = nil, replyTo: Int64? = nil
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
        self.failureKind = failureKind
        self.attempts = attempts
        self.retryAt = retryAt
        self.replyTo = replyTo
    }

    private enum CodingKeys: String, CodingKey {
        case id, serverID, agentID, text, attachments, viaButton, createdAt, state, baseline, maybeDelivered, failure
        case failureKind, attempts, retryAt, replyTo
    }

    /// A file written before `attempts` and the rest existed still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        serverID = try c.decode(UUID.self, forKey: .serverID)
        agentID = try c.decode(String.self, forKey: .agentID)
        text = try c.decode(String.self, forKey: .text)
        attachments = try c.decodeIfPresent([AgentAttachment].self, forKey: .attachments) ?? []
        viaButton = try c.decodeIfPresent(Bool.self, forKey: .viaButton) ?? false
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .waiting
        baseline = try c.decodeIfPresent(Int.self, forKey: .baseline) ?? 0
        maybeDelivered = try c.decodeIfPresent(Bool.self, forKey: .maybeDelivered) ?? false
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        failureKind = try c.decodeIfPresent(Failure.self, forKey: .failureKind)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        retryAt = try c.decodeIfPresent(Int64.self, forKey: .retryAt)
        replyTo = try c.decodeIfPresent(Int64.self, forKey: .replyTo)
    }
}

/// How long to wait before a message is tried again. Pure.
public enum SendBackoff {
    /// The most sends that end without an answer before a message is given up.
    public static let maxAttempts = 5
    public static let ceiling: Int64 = 60_000

    /// 2, 4, 8, 16 … seconds for the n-th try (from 1), never more than a minute.
    public static func delay(attempt: Int) -> Int64 {
        let shift = min(max(attempt, 1), 10)
        return min(ceiling, 1_000 * Int64(1 << shift))
    }

    /// The wait after a rate limit: the backoff, or the server's own word when that is longer.
    public static func rateLimited(attempt: Int, retryAfter: Int64?) -> Int64 {
        max(delay(attempt: attempt), min(retryAfter ?? 0, ceiling))
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
    ///
    /// A message whose text is the same as one the daemon has answered and that has not come back as an event yet waits
    /// for that one: the two events could not be told apart, and a pending row would disappear at the first.
    /// - Parameter now: Unix ms; a message under a wait (`retryAt`) is not offered before it.
    public func next(serverID: UUID, agentID: String, now: Int64 = .max) -> QueuedSend? {
        var sentTexts: Set<String> = []
        for item in items where item.serverID == serverID && item.agentID == agentID {
            switch item.state {
            case .waiting:
                if sentTexts.contains(item.text) { return nil }
                if let at = item.retryAt, at > now { return nil }
                return item
            case .sending, .failed, .uncertain: return nil
            case .sent: sentTexts.insert(item.text)
            }
        }
        return nil
    }

    /// How long until the first waiting message of the agent may go, in ms; nil when nothing waits under a timer.
    public func delay(serverID: UUID, agentID: String, now: Int64) -> Int64? {
        for item in items where item.serverID == serverID && item.agentID == agentID {
            switch item.state {
            case .waiting: return item.retryAt.map { max(0, $0 - now) }
            case .sending, .failed, .uncertain: return nil
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
    /// After `SendBackoff.maxAttempts` such ends the message is given up (`failed`, `gaveUp`); until then it waits an
    /// exponentially longer time (`retryAt`).
    public mutating func interrupted(_ id: String, now: Int64) {
        update(id) {
            $0.attempts += 1
            $0.maybeDelivered = true
            if $0.attempts >= SendBackoff.maxAttempts {
                $0.state = .failed
                $0.failureKind = .gaveUp
                $0.retryAt = nil
            } else {
                $0.state = .waiting
                $0.retryAt = now + SendBackoff.delay(attempt: $0.attempts)
            }
        }
    }

    /// The server limits the rate: back to waiting for `delay` ms (the answer was a refusal, so nothing arrived).
    public mutating func limited(_ id: String, now: Int64, retryAfter: Int64?) {
        update(id) {
            $0.attempts += 1
            $0.state = .waiting
            $0.retryAt = now + SendBackoff.rateLimited(attempt: $0.attempts, retryAfter: retryAfter)
        }
    }

    /// The daemon refused the message, or this device may not send it (`kind`).
    public mutating func refused(_ id: String, reason: String?, kind: QueuedSend.Failure = .refused) {
        update(id) {
            $0.state = .failed
            $0.failure = reason
            $0.failureKind = kind
            $0.maybeDelivered = false
            $0.retryAt = nil
        }
    }

    /// The thread could not be read to tell whether the daemon took the message: the person decides.
    public mutating func uncertain(_ id: String) {
        update(id) {
            $0.state = .uncertain
            $0.retryAt = nil
        }
    }

    /// The person tries a refused message again, or sends an uncertain one once more.
    /// A message that was uncertain or given up may be in the thread already: it stays "maybe delivered", so the thread is
    /// read before it is sent again.
    public mutating func retry(_ id: String) {
        update(id) {
            let maybe = $0.state == .uncertain || ($0.state == .failed && $0.failureKind == .gaveUp)
            $0.state = .waiting
            $0.failure = nil
            $0.failureKind = nil
            $0.attempts = 0
            $0.retryAt = nil
            $0.maybeDelivered = maybe
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

    /// Whether the person's message has come back as an event: after the daemon answered, or later for a message the
    /// queue was not sure about (`uncertain`, or given up after lost answers), which the thread shows it did have.
    public static func hasEcho(_ item: QueuedSend, in items: [ThreadItem]) -> Bool {
        let counts = item.state == .sent || item.state == .uncertain || (item.state == .failed && item.failureKind == .gaveUp)
        return counts && isDelivered(item, in: items)
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
        // Unsent words of a person: not in a backup, and not readable before the first unlock after a restart.
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try? data.write(to: url, options: options)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
