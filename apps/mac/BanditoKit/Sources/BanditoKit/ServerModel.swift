import Foundation
import os
import Observation

/// How the app reaches a server. See docs/ARCHITECTURE.md#transports.
public enum ServerEndpoint: Codable, Sendable, Hashable {
    /// The daemon on this Mac (unix socket, no token).
    case local(socketPath: String)
    /// A WebSocket URL (`ws://127.0.0.1:7878/v1/rpc`, a tailnet address, `wss://…`).
    case webSocket(url: URL)
    /// The daemon on a server reached over ssh. `target` is `[user@]host[:port]` or an alias; `remotePort`
    /// is the daemon's listen port on the server's loopback. See `SSHTransport`.
    case ssh(target: String, remotePort: Int)

    public static var defaultLocal: ServerEndpoint {
        .local(socketPath: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".bandito/bandito.sock").path)
    }
}

/// A saved server.
public struct ServerConfig: Codable, Sendable, Hashable, Identifiable, CustomStringConvertible {
    public var id: UUID
    public var name: String
    public var endpoint: ServerEndpoint
    /// Device token for WebSocket endpoints. The app keeps it in the Keychain; it is never encoded.
    public var token: String?
    /// True for the daemon this app installed on this Mac (`LocalDaemonPairing` sets it). Configs saved before this
    /// flag existed decode as false; `LocalDaemonUpgrade.confirmsThisMac` checks them at launch.
    public var isThisMac: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, isThisMac
    }

    public init(
        id: UUID = UUID(), name: String, endpoint: ServerEndpoint, token: String? = nil, isThisMac: Bool = false
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.token = token
        self.isThisMac = isThisMac
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(ServerEndpoint.self, forKey: .endpoint)
        isThisMac = try container.decodeIfPresent(Bool.self, forKey: .isThisMac) ?? false
    }

    /// For logs and debugging: the name and the kind of connection only. The id, the address and the token
    /// stay out, so a printed config cannot leak them.
    public var description: String {
        let kind = switch endpoint {
        case .local: "local"
        case .webSocket: "WebSocket"
        case .ssh: "ssh"
        }
        return "ServerConfig(name: \(name), connection: \(kind))"
    }
}

public enum ConnectionState: Sendable, Hashable {
    case disconnected
    case connecting
    case connected
    /// The link dropped and the app is retrying. `attempt` counts from 1.
    case reconnecting(attempt: Int)
    case failed(FailureKind)
}

/// Live state of one server: agents, their threads, runtimes. Main-actor
/// observable so SwiftUI views bind to it directly.
@MainActor
@Observable
public final class ServerModel: Identifiable {
    /// Messages per history request (`events.page`).
    public nonisolated static let historyPageSize = 200
    /// Newest events read per agent when the daemon predates `last_message` (see `fillLegacyPreviews`).
    public nonisolated static let legacyPreviewPageSize = 40
    /// Shown when some events could not be decoded: this app is older than the daemon, or a bug.
    /// Some events were skipped because this app does not know their shape: update the app.
    public nonisolated static let decodeWarning = FailureKind.reason("decode_failed")

    public let config: ServerConfig
    public nonisolated var id: UUID { config.id }

    public private(set) var state: ConnectionState = .disconnected {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }
    /// The server answers and refuses this device's key: it stopped there, or it is still being retried (a remote
    /// server) and the last attempt was refused. Cleared by the next successful connection.
    public var refusesKey: Bool {
        if state == .failed(.keyRejected) { return true }
        if case .reconnecting = state { return lastError == .keyRejected }
        return false
    }
    /// Called on the main actor each time `state` changes. The app model repairs a rejected key from it.
    @ObservationIgnored public var onStateChange: (@MainActor (ConnectionState) -> Void)?
    public internal(set) var info: DaemonInfo? {
        didSet {
            // A listing asked for before the daemon's info was known is sent now that it is.
            if info != nil, runtimeModelsWanted {
                Task { _ = try? await self.refreshRuntimeModels() }
            }
        }
    }
    public private(set) var agents: [Agent] = []
    /// When `agents` was last read from the daemon (`agents.list`); nil until the first read.
    public private(set) var agentsReadAt: Date?
    /// Agent changes that arrive close together are answered by one `agents.list` after this delay.
    public nonisolated static let agentsRefreshDelay: Duration = .milliseconds(300)
    /// Coming back to the front re-reads the agents when the last read is older than this (seconds).
    public nonisolated static let agentsStaleAfter: TimeInterval = 30
    /// A refresh is waiting out its delay.
    @ObservationIgnored private var agentsRefreshScheduled = false
    /// An `agents.list` request is in flight.
    @ObservationIgnored private var agentsRefreshing = false
    /// Counts the deletions seen: an `agents.list` answer asked for before one may list the deleted agent, and is dropped.
    @ObservationIgnored private var agentsGeneration = ListGeneration()
    /// A failed `agents.list` is asked again after this delay.
    @ObservationIgnored var agentsRetryDelay: Duration = .seconds(30)
    /// A retry is waiting out its delay.
    @ObservationIgnored private var agentsRetryScheduled = false
    private static let log = Logger(subsystem: "dev.bandito", category: "agents")
    public private(set) var threads: [String: AgentThread] = [:]
    public private(set) var runtimes: [RuntimeStatus] = []
    /// When `runtimes` was last read from the daemon; nil until the first answer.
    public private(set) var runtimesFetchedAt: Date?
    /// The models each agent CLI offers, by runtime raw value (`claude`, `codex`, `grok`). Kept after a later failure.
    public private(set) var runtimeModels: [String: RuntimeModelList] = [:]
    /// What the last request for `runtimeModels` came to. See `RuntimeModelsStatus`.
    public private(set) var runtimeModelsStatus: RuntimeModelsStatus = .unknown
    /// A listing was asked for and waits for the daemon's info.
    private var runtimeModelsWanted = false
    /// Rate-limit windows per runtime, as last learned (from `usage.*` calls or live events).
    public private(set) var usage: [UsageEntry] = []
    /// Why the last `refreshUsage` could not read a runtime, by runtime id.
    public private(set) var usageErrors: [String: String] = [:]
    /// The `usage.refresh` request in flight, if any.
    private var usageRefresh: Task<[UsageEntry], Error>?
    /// When the last `usage.refresh` request started.
    private var usageRefreshStartedAt: Date?
    /// How long an automatic refresh waits after the last request before it asks the runtimes again.
    public static let usageRefreshInterval: TimeInterval = 30
    /// Limits older than this are asked again when a surface opens.
    public static let usageStaleAfter: TimeInterval = UsageFreshness.staleAfter
    /// How often the limits refresh in the background while the app is active.
    public static let usageBackgroundInterval: TimeInterval = 300
    /// The last failure of a background operation (subscription, reconnect, unreadable updates).
    public internal(set) var lastError: FailureKind?
    /// Whether an agent's thread has events older than the ones loaded.
    public private(set) var hasMoreHistory: [String: Bool] = [:]

    private var client: RPCClient?
    private var pump: Task<Void, Never>?
    private var notificationPump: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Attached terminals, by id. Their streams are re-attached after every reconnect.
    @ObservationIgnored var terminalStreams: [String: TerminalStream] = [:]
    /// Port forwarders started by `forwardOnce(port:)`; closed by `disconnect()`.
    @ObservationIgnored var forwarders: [PortForwarder] = []
    /// The transport of the current connection. Its `httpBase` is where the daemon's HTTP routes answer.
    @ObservationIgnored var transport: RPCTransport?
    /// Bumped whenever a connection attempt starts and on disconnect. An attempt that finds the
    /// number changed has been superseded and throws away its client.
    private var generation = 0
    private var decodeFailureCount = 0
    /// Highest persisted event applied. Reconnects resume from here.
    private var lastSeq: Int64 = 0
    /// Oldest persisted event loaded per agent. `loadOlder` pages before it.
    private var oldestSeq: [String: Int64] = [:]
    private let makeTransport: @Sendable (ServerConfig) -> RPCTransport
    private let reconnectDelay: @Sendable (Int) -> Duration

    public init(
        config: ServerConfig,
        makeTransport: (@Sendable (ServerConfig) -> RPCTransport)? = nil,
        reconnectDelay: (@Sendable (Int) -> Duration)? = nil
    ) {
        self.config = config
        self.makeTransport =
            makeTransport ?? { cfg in
                switch cfg.endpoint {
                case .local(let path): return UnixSocketTransport(path: path)
                case .webSocket(let url): return WebSocketTransport(url: url, token: cfg.token)
                case .ssh(let target, let remotePort):
                    #if os(macOS)
                    return SSHTransport(target: target, remotePort: remotePort, token: cfg.token)
                    #else
                    return UnavailableTransport(reason: "ssh servers are not available on this platform yet")
                    #endif
                }
            }
        self.reconnectDelay = reconnectDelay ?? { ServerModel.backoff(attempt: $0) }
    }

    /// 1, 2, 4, 8, 16, then 30 seconds between reconnect attempts.
    public nonisolated static func backoff(attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(max(attempt, 1) - 1, 5)))
    }

    public func thread(for agentId: String) -> AgentThread {
        threads[agentId] ?? AgentThread()
    }

    /// Agents that need a human first, then by name.
    public var sortedAgents: [Agent] {
        agents.sorted { a, b in
            let na = needsPerson(a.id)
            let nb = needsPerson(b.id)
            if na != nb { return na }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The status the team shows for an agent, whether or not its thread is loaded: the newest `agent.status` the app
    /// knows (the daemon's answer, then the live events), else the thread's, else idle.
    public func status(of agentId: String) -> AgentStatus {
        agents.first { $0.id == agentId }?.status ?? threads[agentId]?.status ?? .idle
    }

    /// Approvals of the agent that wait for an answer. A daemon that sends the ids counts the ids (a replayed event
    /// adds or removes nothing twice). An older one sends only a count: the larger of that and the loaded thread's.
    public func pendingApprovalCount(of agentId: String) -> Int {
        guard let agent = agents.first(where: { $0.id == agentId }) else {
            return thread(for: agentId).pendingApprovals.count
        }
        if agent.reportsPendingApprovalIds {
            return agent.pendingApprovalIds.count
        }
        return max(agent.pendingApprovals, thread(for: agentId).pendingApprovals.count)
    }

    /// Needs a person: the status says so, or an approval waits. Drives the "needs you" group and the menu bar.
    public func needsPerson(_ agentId: String) -> Bool {
        status(of: agentId) == .needsYou || pendingApprovalCount(of: agentId) > 0
    }

    // MARK: connection

    /// Connects unless already connecting or connected. A pending reconnect is cancelled in favour of this attempt.
    public func connect() async {
        switch state {
        case .connecting, .connected: return
        case .disconnected, .reconnecting, .failed: break
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        state = .connecting
        // `open` takes the next generation before its first suspension, so this is the attempt it starts.
        let attempt = generation + 1
        do {
            try await open()
        } catch {
            // A superseded attempt (a disconnect, or a newer connect) must not write its failure over the current state.
            guard attempt == generation else { return }
            // A connection lost during this attempt has already scheduled a reconnect: keep retrying instead of giving up.
            if reconnectTask == nil { state = .failed(FailureKind.classify(error)) }
        }
    }

    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        generation += 1
        stopPumps()
        let old = client
        client = nil
        transport = nil
        state = .disconnected
        finishTerminalStreams()
        await stopForwarders()
        await old?.close()
    }

    /// Opens a fresh client, loads agents and subscribes to events. Replaces the previous client.
    /// Throws if the attempt fails or is superseded; the caller owns the state.
    private func open() async throws {
        generation += 1
        let attempt = generation
        await dropClient()
        let current = makeTransport(config)
        transport = current
        let c = RPCClient(
            transport: current,
            onDecodeFailure: { [weak self] in
                Task { @MainActor in self?.noteDecodeFailure() }
            })
        do {
            try await c.start()
            try checkCurrent(attempt)
            client = c
            pump = startPump(c)
            notificationPump = startNotificationPump(c)
            let daemon = try await c.call("daemon.info", NoParams(), as: DaemonInfo.self)
            info = daemon
            if daemon.isSafeMode {
                // A daemon in safe mode answers only `daemon.info` and `backups.*` (docs/ARCHITECTURE.md#backups):
                // stay connected with nothing loaded, so the Backups section can show why and restore a copy.
                try checkCurrent(attempt)
                state = .connected
                lastError = nil
                return
            }
            setAgents(try await c.call("agents.list", NoParams(), as: [Agent].self))
            runtimes = try await c.call("runtimes.status", NoParams(), as: [RuntimeStatus].self)
            runtimesFetchedAt = Date()
            try checkCurrent(attempt)
            // First connection: live events only (the thread is loaded separately).
            // Later connections: everything after what has already been applied.
            let from = lastSeq > 0 ? lastSeq : daemon.lastSeq
            lastSeq = from
            struct Subscribe: Encodable { var after: Int64 }
            struct Subscribed: Decodable { var lastSeq: Int64 }
            let subscribed = try await c.call("events.subscribe", Subscribe(after: from), as: Subscribed.self)
            lastSeq = max(lastSeq, subscribed.lastSeq)
            await reattachTerminals(c)
            try checkCurrent(attempt)
            state = .connected
            lastError = decodeFailureCount > 0 ? Self.decodeWarning : nil
            // A daemon from before `last_message` sends no preview: read the newest messages once, in the background.
            Task { [weak self] in await self?.fillLegacyPreviews(c) }
        } catch {
            if client === c {
                client = nil
                stopPumps()
            }
            await c.close()
            throw error
        }
    }

    private func checkCurrent(_ attempt: Int) throws {
        try Task.checkCancellation()
        guard attempt == generation else { throw CancellationError() }
    }

    private func dropClient() async {
        stopPumps()
        let old = client
        client = nil
        await old?.close()
    }

    /// Consumes the client's events. When the stream ends without `disconnect()`, the link is lost.
    private func startPump(_ c: RPCClient) -> Task<Void, Never> {
        Task { [weak self] in
            for await e in c.events {
                guard let self else { return }
                await self.ingest(e, via: c)
            }
            await self?.connectionLost(c)
        }
    }

    /// Consumes the client's notifications (terminal output and the like).
    private func startNotificationPump(_ c: RPCClient) -> Task<Void, Never> {
        Task { [weak self] in
            for await n in c.notifications {
                guard let self else { return }
                self.routeNotification(n)
            }
        }
    }

    private func stopPumps() {
        pump?.cancel()
        pump = nil
        notificationPump?.cancel()
        notificationPump = nil
    }

    private func connectionLost(_ lost: RPCClient) async {
        // Stale clients (superseded, or closed by disconnect) are ignored.
        guard client === lost else { return }
        client = nil
        stopPumps()
        await lost.close()
        scheduleReconnect()
    }

    /// Retries with backoff until an attempt succeeds or the task is cancelled by `connect` / `disconnect`.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                attempt += 1
                guard let model = self else { return }
                model.state = .reconnecting(attempt: attempt)
                let delay = model.reconnectDelay(attempt)
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
                do {
                    try await model.open()
                    model.reconnectTask = nil
                    return
                } catch {
                    if Task.isCancelled { return }
                    let kind = FailureKind.classify(error)
                    model.lastError = kind
                    // This Mac's own daemon that refuses the key refuses it again: retrying cannot help. A remote
                    // server may answer 401/403 from a proxy or firewall in front of it, so it keeps its backoff.
                    if kind == .keyRejected, LocalDaemonUpgrade.isThisMac(model.config) {
                        model.reconnectTask = nil
                        model.state = .failed(kind)
                        return
                    }
                }
            }
        }
    }

    func noteDecodeFailure() {
        decodeFailureCount += 1
        lastError = Self.decodeWarning
    }

    // MARK: events

    /// Applies one live event from the stream: skips replays, and fills a gap from `events.since`
    /// before applying the event, so the thread always folds in `seq` order.
    private func ingest(_ e: Event, via c: RPCClient) async {
        // Deltas carry no seq and are never replayed.
        guard e.seq > 0 else {
            apply(e)
            return
        }
        if e.seq <= lastSeq { return }
        if e.seq > lastSeq + 1 {
            do {
                try await catchUp(c, through: e.seq - 1)
            } catch {
                // Drop the connection: the reconnect resubscribes from lastSeq, which backfills the gap.
                lastError = FailureKind.classify(error)
                await c.close()
                return
            }
            if e.seq <= lastSeq { return }
        }
        apply(e)
        onLiveEvent?(e)
    }

    /// Fetches `events.since` pages until `lastSeq` reaches `last`, applying them in order.
    private func catchUp(_ c: RPCClient, through last: Int64) async throws {
        struct Since: Encodable { var after: Int64; var limit: Int }
        while lastSeq < last {
            let before = lastSeq
            let page = try await c.call("events.since", Since(after: before, limit: 1000), as: [Event].self)
            for e in page where e.seq > lastSeq {
                apply(e)
            }
            // A page that moves nothing would loop forever; stop and let the caller decide.
            if lastSeq == before { break }
        }
    }

    /// Called for each event that arrives live (not for history fetched to fill a gap). The app uses it
    /// for notifications, so events that were already seen never notify twice.
    public var onLiveEvent: ((Event) -> Void)?

    /// Fold one event into the model (also used by tests).
    public func apply(_ e: Event) {
        if e.seq > lastSeq { lastSeq = e.seq }
        if case .usageLimits(let runtime, let windows) = e.body {
            recordUsage(runtime: runtime, windows: windows)
        }
        // Records change from any client or path: created and updated agents are read again, deleted ones leave
        // the list. An event from an agent the list does not have (it was made elsewhere) asks for the list too.
        if case .agentChanged(let action) = e.body {
            switch action {
            case .deleted:
                agentsGeneration.advance()
                agents.removeAll { $0.id == e.agentId }
            case .created, .updated:
                requestAgentsRefresh()
            }
        } else if !agents.contains(where: { $0.id == e.agentId }) {
            requestAgentsRefresh()
        }
        // The team's view of the agent follows its live events: newest message, status, pending approvals.
        if let i = agents.firstIndex(where: { $0.id == e.agentId }) {
            switch e.body {
            case .agentStatus(let status, _):
                agents[i].status = status
            case .approvalRequested(let approvalId, _, _, _, _, _, _):
                if agents[i].reportsPendingApprovalIds {
                    agents[i].pendingApprovalIds.insert(approvalId)
                } else {
                    agents[i].pendingApprovals += 1
                }
            case .approvalResolved(let approvalId, _, _, _):
                if agents[i].reportsPendingApprovalIds {
                    agents[i].pendingApprovalIds.remove(approvalId)
                } else {
                    agents[i].pendingApprovals = max(0, agents[i].pendingApprovals - 1)
                }
            case .turnCompleted:
                // The daemon stores the context the turn left when the turn ends; the ring and the memory tab read it
                // from the list.
                requestAgentsRefresh()
            case .sessionRotated(let chapter, _, _):
                agents[i].chapter = chapter
                agents[i].contextTokens = 0
            default:
                break
            }
            if let message = LastMessage(event: e) {
                agents[i].lastMessage = message
            }
        }
        threads[e.agentId, default: AgentThread()].apply(e)
    }

    /// Reads the newest messages of agents that a daemon from before `last_message` did not report, so the sidebar can
    /// show a preview. One page per agent (`legacyPreviewPageSize` events); a message that arrived live meanwhile wins.
    /// An agent whose read fails is tried again at the next connection.
    func fillLegacyPreviews(_ c: RPCClient) async {
        let ids = agents.filter { !$0.reportsLastMessage }.map(\.id)
        for id in ids {
            guard let page = try? await c.call(
                "events.page",
                PageRequest(agentId: id, before: nil, limit: Self.legacyPreviewPageSize),
                as: [Event].self)
            else { continue }
            guard client === c, let i = agents.firstIndex(where: { $0.id == id }) else { return }
            let newest = page.reversed().lazy.compactMap { LastMessage(event: $0) }.first
            if let newest, newest.ts > (agents[i].lastMessage?.ts ?? 0) {
                agents[i].lastMessage = newest
            }
            agents[i].reportsLastMessage = true
        }
    }

    private func recordUsage(runtime: String, windows: [LimitWindow]) {
        let entry = UsageEntry(runtime: runtime, windows: windows, updatedAt: Self.nowMs())
        if let i = usage.firstIndex(where: { $0.runtime == runtime }) {
            usage[i] = entry
        } else {
            usage.append(entry)
        }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func setAgents(_ list: [Agent]) {
        agents = list
        agentsReadAt = Date()
    }

    /// The daemon runs in safe mode: it answers only `daemon.info` and `backups.*`, so nothing else is asked.
    private var inSafeMode: Bool { info?.isSafeMode == true }

    /// Reads `agents.list` after `agentsRefreshDelay`. Requests that come meanwhile share that one read.
    private func requestAgentsRefresh() {
        guard !inSafeMode, !agentsRefreshScheduled else { return }
        agentsRefreshScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.agentsRefreshDelay)
            await self?.runAgentsRefresh()
        }
    }

    /// One `agents.list` at a time: a refresh asked for while one is in flight is asked again after it. A failed read
    /// is logged and asked again after `agentsRetryDelay`; its time counts as the last read, so the app coming back to
    /// the front does not ask again at once.
    private func runAgentsRefresh() async {
        agentsRefreshScheduled = false
        guard !inSafeMode else { return }
        guard !agentsRefreshing else {
            requestAgentsRefresh()
            return
        }
        guard let c = client else { return }
        agentsRefreshing = true
        defer { agentsRefreshing = false }
        let generation = agentsGeneration
        do {
            let list = try await c.call("agents.list", NoParams(), as: [Agent].self)
            guard client === c else { return }
            guard agentsGeneration.accepts(generation) else {
                // An agent was deleted while the answer was on its way: that answer may still list it.
                requestAgentsRefresh()
                return
            }
            setAgents(list)
        } catch {
            guard client === c else { return }
            Self.log.error("agents.list failed: \(String(describing: error), privacy: .public)")
            agentsReadAt = Date()
            scheduleAgentsRetry()
        }
    }

    private func scheduleAgentsRetry() {
        guard !inSafeMode, !agentsRetryScheduled else { return }
        agentsRetryScheduled = true
        let delay = agentsRetryDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.agentsRetryScheduled = false
            // A daemon that went into safe mode meanwhile refuses `agents.list`: no retry.
            self.requestAgentsRefresh()
        }
    }

    /// Called when the app comes back to the front. Re-reads the agents when the last read is older than
    /// `agentsStaleAfter`: a daemon from before `agent_changed` sends no event for changes made elsewhere.
    public func refreshAgentsIfStale(now: Date = Date()) {
        guard state == .connected, !inSafeMode else { return }
        let stale = agentsReadAt.map { now.timeIntervalSince($0) > Self.agentsStaleAfter } ?? true
        if stale { requestAgentsRefresh() }
    }

    private func replaceAgent(_ a: Agent) {
        if let i = agents.firstIndex(where: { $0.id == a.id }) { agents[i] = a } else { agents.append(a) }
    }

    func rpc() throws -> RPCClient {
        guard let client else { throw RPCError(code: RPCError.disconnected, message: "not connected to \(config.name)") }
        return client
    }

    // MARK: history

    private struct PageRequest: Encodable {
        var agentId: String
        var before: Int64?
        var limit: Int = ServerModel.historyPageSize
    }

    /// Loads the newest page of an agent's thread. Live state that arrived meanwhile
    /// (streaming text, status, turn flag) is kept.
    public func loadHistory(_ agentId: String) async throws {
        let page = try await rpc().call(
            "events.page", PageRequest(agentId: agentId, before: nil), as: [Event].self)
        var t = AgentThread()
        for e in page { t.apply(e) }
        if let live = threads[agentId] {
            let pageIds = Set(t.items.map(\.id))
            // Live items after the last item of the page; older items already loaded by `loadOlder` stay out.
            let anchor = live.items.lastIndex(where: { pageIds.contains($0.id) })
            let tail = anchor.map { Array(live.items.dropFirst($0 + 1)) } ?? live.items
            for item in tail where !pageIds.contains(item.id) {
                t.items.append(item)
            }
            t.status = live.status
            t.statusDetail = live.statusDetail
            t.turnRunning = live.turnRunning
            t.turnStartedAt = live.turnStartedAt
            t.lastSeq = max(t.lastSeq, live.lastSeq)
            t.mergeMessageMeta(from: live)
        }
        threads[agentId] = t
        oldestSeq[agentId] = page.first?.seq
        hasMoreHistory[agentId] = !page.isEmpty && page.count == Self.historyPageSize
        await addOpenForms(agentId)
    }

    /// A form that still waits can be older than the page that was loaded: the daemon holds it for a day. It is added
    /// to the thread, so the person sees what the agent is waiting for. A failed read leaves the thread as it is.
    private func addOpenForms(_ agentId: String) async {
        guard supports("forms"), let c = try? rpc() else { return }
        struct P: Encodable { var agentId: String; var status: String }
        guard let open = try? await c.call("forms.list", P(agentId: agentId, status: "pending"), as: [FormRecord].self)
        else { return }
        guard var thread = threads[agentId] else { return }
        for record in open.reversed() {
            thread.addPending(form: FormRow(formId: record.id, spec: record.spec, outcome: nil, ts: record.createdAt))
        }
        threads[agentId] = thread
    }

    /// Prepends the page before the oldest loaded event.
    public func loadOlder(_ agentId: String) async throws {
        guard let before = oldestSeq[agentId] else { return }
        let page = try await rpc().call(
            "events.page", PageRequest(agentId: agentId, before: before), as: [Event].self)
        var older = AgentThread()
        for e in page { older.apply(e) }
        var current = threads[agentId] ?? AgentThread()
        let known = Set(current.items.map(\.id))
        current.items = older.items.filter { !known.contains($0.id) } + current.items
        current.mergeMessageMeta(from: older)
        threads[agentId] = current
        if let oldest = page.first?.seq { oldestSeq[agentId] = oldest }
        hasMoreHistory[agentId] = !page.isEmpty && page.count == Self.historyPageSize
    }

    // MARK: actions

    /// Sends a message to an agent. `attachments` are files from `uploadAttachment`; they go by path. `replyTo` is the
    /// `seq` of the message it answers (the daemon takes it with the `attachments` feature; without that feature the
    /// field is left out and the text goes alone). `mentions` go with the `mentions` feature; without it the text
    /// keeps the `@Name` words and nothing more.
    public func send(
        _ text: String, to agentId: String, replyTo: Int64? = nil, attachments: [AgentAttachment] = [],
        mentions: [Mention] = []
    ) async throws {
        let request = AgentSendRequest(
            agentId: agentId, text: text, attachments: attachments.isEmpty ? nil : attachments.map(\.path),
            replyTo: supports("attachments") ? replyTo : nil,
            mentions: mentions.isEmpty || !supports("mentions") ? nil : mentions)
        try await rpc().call("agents.send", request)
    }

    /// Sends an undelivered message again, with its files, the message it answered and its mentions. A mention that
    /// is not available any more (a service taken off the agent, a closed tab, a deleted file or teammate) is left
    /// out and returned, so the send does not fail on it. The line "Not delivered" goes away at once, so a second
    /// click does nothing; a failed send brings it back.
    @discardableResult
    public func resendUndelivered(_ seq: Int64, of agentId: String) async throws -> [Mention] {
        guard var thread = threads[agentId], thread.undeliveredSeqs.contains(seq),
            case .user(_, let text, _, _, _, _)? = thread.items.first(where: { $0.id == ThreadItem.messageID(seq: seq) })
        else { return [] }
        let files = thread.attachments[seq] ?? []
        let replyTo = thread.replies[seq]
        thread.markResent(seq)
        threads[agentId] = thread
        var dropped: [Mention] = []
        do {
            var mentions = thread.mentions[seq] ?? []
            if !mentions.isEmpty, supports("mentions") {
                let split = await availableMentions(mentions, agentId: agentId)
                mentions = split.kept
                dropped = split.dropped
            }
            try await send(text, to: agentId, replyTo: replyTo, attachments: files, mentions: mentions)
        } catch {
            threads[agentId]?.unmarkResent(seq)
            throw error
        }
        return dropped
    }

    /// The mentions that are still good, asked of the daemon. A failed question counts as "not available".
    private func availableMentions(_ mentions: [Mention], agentId: String) async -> MentionResend {
        var integrations: Set<String> = []
        if mentions.contains(where: { $0.kind == .integration }), supports("integrations"),
            let list = try? await self.integrations()
        {
            let own = agents.first { $0.id == agentId }?.integrations.map(Set.init)
            integrations = Set(list.filter { $0.enabled && (own?.contains($0.id) ?? true) }.map(\.id))
        }
        var tabs: Set<String>?
        if mentions.contains(where: { $0.kind == .browserTab }), supports("browser"),
            let status = try? await browserStatus(), status.isRelay, let pages = try? await browserTabs()
        {
            tabs = Set(pages.map(\.id))
        }
        var files: Set<String> = []
        if supports("files") {
            for mention in mentions where mention.kind == .file {
                if (try? await stat(mention.id)) != nil { files.insert(mention.id) }
            }
        }
        return MentionResend.split(
            mentions, integrations: integrations, agents: Set(agents.map(\.id)), tabs: tabs, files: files)
    }

    /// Saves one file in the agent's attachment folder (`attachments.upload`). The daemon refuses more than 20 MB.
    public func uploadAttachment(_ data: Data, name: String, agentId: String) async throws -> AgentAttachment {
        struct P: Encodable { var agentId: String; var name: String; var dataBase64: String }
        return try await rpc().call(
            "attachments.upload",
            P(agentId: agentId, name: name, dataBase64: data.base64EncodedString()),
            as: AgentAttachment.self)
    }

    /// Throws `unsupported` when the daemon does not list `feature`: the call would only be refused as an unknown method.
    private func requireFeature(_ feature: String) throws {
        guard supports(feature) else {
            throw RPCError(code: RPCError.invalidParams, message: "unsupported: \(feature) is not available on this server")
        }
    }

    /// Puts an emoji on a message, or takes the person's reaction off with `nil` (`messages.react`). The thread shows
    /// it when the daemon's `reaction` event arrives.
    public func react(_ emoji: String?, toMessage seq: Int64, of agentId: String) async throws {
        try requireFeature("reactions")
        struct P: Encodable {
            var agentId: String; var seq: Int64; var emoji: String?
            // The daemon reads a missing `emoji` as null, but an explicit null says it plainly.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(agentId, forKey: .agentId)
                try c.encode(seq, forKey: .seq)
                try c.encode(emoji, forKey: .emoji)
            }
            enum Keys: String, CodingKey { case agentId, seq, emoji }
        }
        try await rpc().call("messages.react", P(agentId: agentId, seq: seq, emoji: emoji))
    }

    /// Answers a form (`forms.answer`). The answer reaches the thread as the daemon's `form_answered` event. A form the
    /// daemon says is over (`expired`) is closed in the thread at once; the error is still thrown for the card to show.
    public func answerForm(
        _ formId: String, in agentId: String, action: FormAction, values: [String: JSONValue]? = nil,
        comment: String? = nil
    ) async throws {
        try requireFeature("forms")
        let params = try FormAnswer.answerParams(formId: formId, action: action, values: values, comment: comment)
        do {
            try await rpc().call("forms.answer", jsonParams: params)
        } catch let error as RPCError where error.message == "expired" {
            threads[agentId]?.close(form: formId, with: .expired)
            throw error
        }
    }

    public func interrupt(_ agentId: String) async throws {
        struct P: Encodable { var agentId: String }
        try await rpc().call("agents.interrupt", P(agentId: agentId))
    }

    /// Starts the agent's next chapter now (`agents.new_chapter`). The memory is saved first; a running turn finishes
    /// before the new chapter starts, so the reply comes back at once.
    public func startNewChapter(_ agentId: String) async throws {
        struct P: Encodable { var id: String }
        try await rpc().call("agents.new_chapter", P(id: agentId))
    }

    public func resolve(_ approvalId: String, _ decision: Decision, remember: Bool = false) async throws {
        struct P: Encodable { var approvalId: String; var decision: Decision; var remember: Bool }
        try await rpc().call("approvals.resolve", P(approvalId: approvalId, decision: decision, remember: remember))
    }

    @discardableResult
    public func createAgent(_ a: NewAgent) async throws -> Agent {
        let created = try await rpc().call("agents.create", a, as: Agent.self)
        replaceAgent(created)
        return created
    }

    /// Pauses or resumes one agent (`agents.update {paused}`). Returns the agent as the daemon now has it.
    @discardableResult
    public func setPaused(agentID: String, _ paused: Bool) async throws -> Agent {
        try await updateAgent(agentID, patch: AgentPatch(paused: paused)).agent
    }

    /// Makes the agent the main one of the server, or takes the role away (`agents.update {lead}`). The daemon takes
    /// the role from the old main agent in the same step; the list here follows at once, and the `agent_changed`
    /// events read it again.
    @discardableResult
    public func setLead(agentID: String, _ lead: Bool) async throws -> Agent {
        let agent = try await updateAgent(agentID, patch: AgentPatch(lead: lead)).agent
        if lead {
            for i in agents.indices where agents[i].id != agentID && agents[i].lead { agents[i].lead = false }
        }
        return agent
    }

    /// The id of the main agent of this server, or `nil` when there is none (or the daemon has no such thing).
    public var leadAgentID: String? {
        supports("lead") ? agents.first(where: \.lead)?.id : nil
    }

    /// Stores the agent's picture (`agents.avatar_image_set`): a PNG or JPEG of at most 1 MB. The daemon needs the
    /// avatar set first. Returns the agent, with its new `image_rev`.
    @discardableResult
    public func setAgentAvatarImage(_ agentID: String, _ data: Data) async throws -> Agent {
        struct P: Encodable {
            var id: String
            var dataBase64: String

            enum CodingKeys: String, CodingKey {
                case id
                case dataBase64 = "data_base64"
            }
        }
        let agent = try await rpc().call(
            "agents.avatar_image_set", P(id: agentID, dataBase64: data.base64EncodedString()), as: Agent.self)
        replaceAgent(agent)
        return agent
    }

    /// The agent's picture (`agents.avatar_image_get`), or nil when it has none.
    public func agentAvatarImage(_ agentID: String) async throws -> AvatarImage? {
        struct P: Encodable { var id: String }
        return try await rpc().call("agents.avatar_image_get", P(id: agentID), as: AvatarImage?.self)
    }

    /// Removes the agent's picture (`agents.avatar_image_clear`). Returns the agent.
    @discardableResult
    public func clearAgentAvatarImage(_ agentID: String) async throws -> Agent {
        struct P: Encodable { var id: String }
        let agent = try await rpc().call("agents.avatar_image_clear", P(id: agentID), as: Agent.self)
        replaceAgent(agent)
        return agent
    }

    /// The newest lines of the daemon's own log (`daemon.logs`). `level` is the lowest level to show.
    public func daemonLog(lines: Int = 500, level: DaemonLogLevel? = nil) async throws -> DaemonLog {
        struct P: Encodable {
            var lines: Int
            var level: String?
        }
        return try await rpc().call("daemon.logs", P(lines: lines, level: level?.rawValue), as: DaemonLog.self)
    }

    /// Pauses or resumes every agent (`agents.pause_all`). Returns how many changed, and reloads the agents
    /// (the daemon sends no event for it).
    @discardableResult
    public func pauseAll(_ paused: Bool) async throws -> Int {
        struct P: Encodable { var paused: Bool }
        struct Reply: Decodable { var changed: Int }
        let reply = try await rpc().call("agents.pause_all", P(paused: paused), as: Reply.self)
        setAgents(try await rpc().call("agents.list", NoParams(), as: [Agent].self))
        return reply.changed
    }

    public func deleteAgent(_ id: String) async throws {
        struct P: Encodable { var id: String }
        try await rpc().call("agents.delete", P(id: id))
        agentsGeneration.advance()
        agents.removeAll { $0.id == id }
        threads[id] = nil
        oldestSeq[id] = nil
        hasMoreHistory[id] = nil
    }

    /// Whether the daemon reports `feature` in `daemon.info` (for example `files`, `terminals`).
    public func supports(_ feature: String) -> Bool {
        info?.supports(feature) ?? false
    }

    /// Whether the connected daemon knows `agents.new_chapter` (see `DaemonInfo.supportsNewChapter`).
    public var supportsNewChapter: Bool { info?.supportsNewChapter ?? false }

    /// Current rate-limit windows of every runtime (cached by the daemon).
    @discardableResult
    public func usageLimits() async throws -> [UsageEntry] {
        let entries = try await rpc().call("usage.limits", NoParams(), as: [UsageEntry].self)
        usage = entries
        return entries
    }

    /// Asks the runtimes that can be asked for fresh limits, then returns them. A runtime that could not be asked
    /// is listed in `usageErrors` with the reason; the limits it had before stay.
    ///
    /// One request is in flight at a time: a call while one runs waits for it. Without `force`, a call within
    /// `usageRefreshInterval` of the last request returns the limits already known. `force` (the refresh button)
    /// skips that wait, but still does not run in parallel.
    @discardableResult
    public func refreshUsage(force: Bool = false) async throws -> [UsageEntry] {
        if let inFlight = usageRefresh {
            return try await inFlight.value
        }
        if !force, let last = usageRefreshStartedAt, Date().timeIntervalSince(last) < Self.usageRefreshInterval {
            return usage
        }
        usageRefreshStartedAt = Date()
        let task = Task { () throws -> [UsageEntry] in
            try await self.askRuntimesForUsage()
        }
        usageRefresh = task
        defer { usageRefresh = nil }
        return try await task.value
    }

    /// True when no limits are known yet, or the newest ones were received more than `usageStaleAfter` ago.
    public var usageIsStale: Bool {
        UsageFreshness.isStale(usage, now: Date(), after: Self.usageStaleAfter)
    }

    /// Asks the runtimes for fresh limits when the known ones are stale. Otherwise does nothing.
    public func refreshUsageIfStale() async {
        guard usageIsStale else { return }
        _ = try? await refreshUsage()
    }

    /// The `usage.refresh` call itself.
    private func askRuntimesForUsage() async throws -> [UsageEntry] {
        struct Refusal: Decodable { var runtime: String; var message: String }
        struct Reply: Decodable { var limits: [UsageEntry]; var errors: [Refusal] }
        let reply = try await rpc().call("usage.refresh", NoParams(), as: Reply.self)
        usage = reply.limits
        usageErrors = Dictionary(reply.errors.map { ($0.runtime, $0.message) }, uniquingKeysWith: { first, _ in first })
        return reply.limits
    }
}

// MARK: - Settings-level API (rules, schedules, devices, runtimes)

extension ServerModel {
    public func refreshRuntimes() async throws {
        runtimes = try await rpc().call("runtimes.status", NoParams(), as: [RuntimeStatus].self)
        runtimesFetchedAt = Date()
    }

    /// Asks the daemon which models each agent CLI offers. `refresh` skips the daemon's 15-minute cache.
    /// Until the daemon's info is known the request waits and is sent when the info arrives. A daemon without
    /// `runtime_models` is not asked: the status becomes `.unsupported`, which is not the same as a failed request.
    public func refreshRuntimeModels(refresh: Bool = false) async throws {
        runtimeModelsWanted = true
        let gate = RuntimeModelsGate.decide(
            hasInfo: info != nil, supportsModels: info?.supports("runtime_models") ?? false)
        switch gate {
        case .wait:
            return
        case .unsupported:
            runtimeModelsWanted = false
            runtimeModelsStatus = .unsupported
            return
        case .ask:
            break
        }
        runtimeModelsWanted = false
        struct P: Encodable { var refresh: Bool }
        do {
            let lists = try await rpc().call("runtimes.models", P(refresh: refresh), as: [RuntimeModelList].self)
            runtimeModels = Dictionary(
                lists.map { ($0.runtime.rawValue, $0) }, uniquingKeysWith: { _, last in last })
            runtimeModelsStatus = .loaded
        } catch {
            runtimeModelsStatus = .failed((error as? RPCError)?.message ?? error.localizedDescription)
            throw error
        }
    }

    public func rules(agentId: String? = nil) async throws -> [Rule] {
        struct P: Encodable { var agentId: String? }
        return try await rpc().call("rules.list", P(agentId: agentId), as: [Rule].self)
    }

    @discardableResult
    public func setRule(pattern: String, action: RuleAction, agentId: String? = nil) async throws -> Rule {
        struct P: Encodable { var agentId: String?; var pattern: String; var action: RuleAction }
        return try await rpc().call("rules.set", P(agentId: agentId, pattern: pattern, action: action), as: Rule.self)
    }

    public func deleteRule(_ id: String) async throws {
        struct P: Encodable { var id: String }
        try await rpc().call("rules.delete", P(id: id))
    }

    public func schedules(agentId: String? = nil) async throws -> [Schedule] {
        struct P: Encodable { var agentId: String? }
        return try await rpc().call("schedules.list", P(agentId: agentId), as: [Schedule].self)
    }

    /// Creates an owner schedule. `cron` is the expression in the server's zone `tz`; `title` is optional.
    @discardableResult
    public func createSchedule(
        agentId: String, cron: String, tz: String, prompt: String, title: String? = nil
    ) async throws -> Schedule {
        struct P: Encodable { var agentId: String; var cron: String; var tz: String; var prompt: String; var title: String? }
        return try await rpc().call(
            "schedules.create", P(agentId: agentId, cron: cron, tz: tz, prompt: prompt, title: title), as: Schedule.self)
    }

    /// Changes the fields that are set. `title` `.clear` sends `null`, which removes the title.
    @discardableResult
    public func updateSchedule(
        _ id: String, cron: String? = nil, tz: String? = nil, prompt: String? = nil, enabled: Bool? = nil,
        title: FieldChange<String>? = nil
    ) async throws -> Schedule {
        let params = ScheduleUpdateParams(
            id: id, cron: cron, tz: tz, prompt: prompt, enabled: enabled, title: title)
        return try await rpc().call("schedules.update", params, as: Schedule.self)
    }

    public func deleteSchedule(_ id: String) async throws {
        struct P: Encodable { var id: String }
        try await rpc().call("schedules.delete", P(id: id))
    }

    public func runScheduleNow(_ id: String) async throws {
        struct P: Encodable { var id: String }
        try await rpc().call("schedules.run_now", P(id: id))
    }

    public func devices() async throws -> [Device] {
        try await rpc().call("devices.list", NoParams(), as: [Device].self)
    }

    public func revokeDevice(_ id: String) async throws {
        struct P: Encodable { var id: String }
        try await rpc().call("devices.revoke", P(id: id))
    }

    @discardableResult
    public func updateAgent(
        _ id: String, name: String? = nil, role: String? = nil, cwd: String? = nil, approvalMode: ApprovalMode? = nil,
        effort: Effort? = nil, memoryMode: MemoryMode? = nil, contextBudget: Int? = nil,
        systemPrompt: String? = nil, model: String? = nil
    ) async throws -> Agent {
        try await updateAgent(
            id,
            patch: AgentPatch(
                name: name, role: role, cwd: cwd, approvalMode: approvalMode, effort: effort,
                memoryMode: memoryMode, contextBudget: contextBudget, systemPrompt: systemPrompt,
                model: model.map { .set($0) })
        ).agent
    }

    /// Applies `patch` (`agents.update`). Returns the agent and the daemon's warnings.
    @discardableResult
    public func updateAgent(_ id: String, patch: AgentPatch) async throws -> AgentUpdate {
        struct P: Encodable {
            var id: String
            var patch: AgentPatch

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: AgentPatch.Key.self)
                try c.encode(id, forKey: .id)
                try patch.encodeFields(into: &c)
            }
        }
        let update = try await rpc().call("agents.update", P(id: id, patch: patch), as: AgentUpdate.self)
        replaceAgent(update.agent)
        return update
    }
}

/// Pairing happens on an unauthenticated connection: redeem the six-word code
/// from `bandito pair` for a device token.
public enum Pairing {
    public static func redeem(url: URL, code: String, deviceName: String) async throws -> PairResult {
        // The code is as good as a token for ten minutes: same rule as for tokens.
        guard WebSocketTransport.allowsToken(for: url) else {
            throw RPCError(
                code: RPCError.insecureTransport,
                message: "refusing to send the pairing code over an unencrypted connection")
        }
        let client = RPCClient(transport: WebSocketTransport(url: url, token: nil))
        try await client.start()
        defer { Task { await client.close() } }
        struct P: Encodable { var code: String; var deviceName: String }
        return try await client.call("pair.redeem", P(code: code, deviceName: deviceName), as: PairResult.self)
    }

    /// Revokes a device on the daemon (`devices.revoke`), over a connection that the token itself opens. Used when
    /// the app cannot keep a token it was just given, so the daemon does not keep a device nobody holds.
    public static func revoke(url: URL, token: String, deviceID: String) async throws {
        guard WebSocketTransport.allowsToken(for: url) else {
            throw RPCError(
                code: RPCError.insecureTransport,
                message: "refusing to send the device token over an unencrypted connection")
        }
        let client = RPCClient(transport: WebSocketTransport(url: url, token: token))
        try await client.start()
        defer { Task { await client.close() } }
        struct P: Encodable { var id: String }
        struct Revoked: Decodable { var revoked: Bool }
        _ = try await client.call("devices.revoke", P(id: deviceID), as: Revoked.self)
    }
}

/// The daemon's log lines, as `daemon.logs` returns them.
public struct DaemonLog: Decodable, Sendable, Equatable {
    /// Where the lines came from: `journald` or `file`.
    public var source: String
    /// Newest last. Secrets and tokens are already masked by the daemon.
    public var lines: [String]
}

/// The lowest level `daemon.logs` shows.
public enum DaemonLogLevel: String, CaseIterable, Sendable {
    case info, warn, error
}

/// When the limits of a server were last received. Pure, so the rule is tested without a server.
public enum UsageFreshness {
    /// Limits older than this many seconds are stale.
    public static let staleAfter: TimeInterval = 120

    /// True when `entries` is empty, or the newest of them was received more than `after` seconds before `now`.
    public static func isStale(_ entries: [UsageEntry], now: Date, after: TimeInterval) -> Bool {
        guard let newest = entries.map(\.updatedAt).max() else { return true }
        return now.timeIntervalSince1970 - Double(newest) / 1000 > after
    }
}

/// Counts the changes that make an `agents.list` answer out of date. A read takes the value when it is asked for; its
/// answer is used only while the value is still the same.
struct ListGeneration: Sendable, Equatable {
    private(set) var value = 0

    mutating func advance() {
        value += 1
    }

    func accepts(_ generation: ListGeneration) -> Bool {
        generation == self
    }
}

/// `schedules.update` params: the id and the fields that are set. `title` `.clear` is sent as `null`.
struct ScheduleUpdateParams: Encodable, Sendable {
    var id: String
    var cron: String?
    var tz: String?
    var prompt: String?
    var enabled: Bool?
    var title: FieldChange<String>?

    enum Key: String, CodingKey { case id, cron, tz, prompt, enabled, title }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(cron, forKey: .cron)
        try c.encodeIfPresent(tz, forKey: .tz)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        switch title {
        case nil: break
        case .set(let value)?: try c.encode(value, forKey: .title)
        case .clear?: try c.encodeNil(forKey: .title)
        }
    }
}
