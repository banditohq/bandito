import Foundation
import Observation

/// How the app reaches a server. See docs/ARCHITECTURE.md#transports.
public enum ServerEndpoint: Codable, Sendable, Hashable {
    /// The daemon on this Mac (unix socket, no token).
    case local(socketPath: String)
    /// A WebSocket URL (`ws://127.0.0.1:7878/v1/rpc` via an SSH tunnel, a tailnet address, `wss://…`).
    case webSocket(url: URL)

    public static var defaultLocal: ServerEndpoint {
        .local(socketPath: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".bandito/bandito.sock").path)
    }
}

/// A saved server.
public struct ServerConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var endpoint: ServerEndpoint
    /// Device token for WebSocket endpoints (kept in the Keychain by the app; here only in memory).
    public var token: String?

    public init(id: UUID = UUID(), name: String, endpoint: ServerEndpoint, token: String? = nil) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.token = token
    }
}

public enum ConnectionState: Sendable, Hashable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// Live state of one server: agents, their threads, runtimes. Main-actor
/// observable so SwiftUI views bind to it directly.
@MainActor
@Observable
public final class ServerModel: Identifiable {
    public let config: ServerConfig
    public nonisolated var id: UUID { config.id }

    public private(set) var state: ConnectionState = .disconnected
    public private(set) var info: DaemonInfo?
    public private(set) var agents: [Agent] = []
    public private(set) var threads: [String: AgentThread] = [:]
    public private(set) var runtimes: [RuntimeStatus] = []
    public private(set) var limits: [String: [LimitWindow]] = [:]

    private var client: RPCClient?
    private var pump: Task<Void, Never>?
    /// Highest persisted event seen; reconnects resume from here.
    private var lastSeq: Int64 = 0
    private let makeTransport: @Sendable (ServerConfig) -> RPCTransport

    public init(config: ServerConfig, makeTransport: (@Sendable (ServerConfig) -> RPCTransport)? = nil) {
        self.config = config
        self.makeTransport =
            makeTransport ?? { cfg in
                switch cfg.endpoint {
                case .local(let path): return UnixSocketTransport(path: path)
                case .webSocket(let url): return WebSocketTransport(url: url, token: cfg.token)
                }
            }
    }

    public func thread(for agentId: String) -> AgentThread {
        threads[agentId] ?? AgentThread()
    }

    /// Agents that need a human first, then by name.
    public var sortedAgents: [Agent] {
        agents.sorted { a, b in
            let na = thread(for: a.id).status == .needsYou
            let nb = thread(for: b.id).status == .needsYou
            if na != nb { return na }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    public func connect() async {
        if case .connecting = state { return }
        state = .connecting
        let c = RPCClient(transport: makeTransport(config))
        do {
            try await c.start()
            client = c
            info = try await c.call("daemon.info", NoParams(), as: DaemonInfo.self)
            agents = try await c.call("agents.list", NoParams(), as: [Agent].self)
            runtimes = try await c.call("runtimes.status", NoParams(), as: [RuntimeStatus].self)
            startPump(c)
            struct Sub: Encodable { var after: Int64 }
            _ = try await c.call("events.subscribe", Sub(after: lastSeq), as: JSONValue.self)
            state = .connected
        } catch {
            await c.close()
            client = nil
            state = .failed(error.localizedDescription)
        }
    }

    public func disconnect() async {
        pump?.cancel()
        pump = nil
        await client?.close()
        client = nil
        state = .disconnected
    }

    private func startPump(_ c: RPCClient) {
        pump?.cancel()
        pump = Task { [weak self] in
            for await e in c.events {
                self?.apply(e)
            }
            self?.connectionLost()
        }
    }

    private func connectionLost() {
        if case .connected = state {
            state = .failed("connection lost")
            client = nil
        }
    }

    /// Fold one event into the model (also used by tests).
    public func apply(_ e: Event) {
        if e.seq > lastSeq { lastSeq = e.seq }
        if case .usageLimits(let runtime, let windows) = e.body {
            limits[runtime] = windows
        }
        var t = threads[e.agentId] ?? AgentThread()
        t.apply(e)
        threads[e.agentId] = t
    }

    private func rpc() throws -> RPCClient {
        guard let client else { throw RPCError(code: RPCError.disconnected, message: "not connected to \(config.name)") }
        return client
    }

    // MARK: actions

    public func send(_ text: String, to agentId: String) async throws {
        struct P: Encodable { var agentId: String; var text: String }
        try await rpc().call("agents.send", P(agentId: agentId, text: text))
    }

    public func interrupt(_ agentId: String) async throws {
        struct P: Encodable { var agentId: String }
        try await rpc().call("agents.interrupt", P(agentId: agentId))
    }

    public func resolve(_ approvalId: String, _ decision: Decision, remember: Bool = false) async throws {
        struct P: Encodable { var approvalId: String; var decision: Decision; var remember: Bool }
        try await rpc().call("approvals.resolve", P(approvalId: approvalId, decision: decision, remember: remember))
    }

    @discardableResult
    public func createAgent(_ a: NewAgent) async throws -> Agent {
        let created = try await rpc().call("agents.create", a, as: Agent.self)
        agents.append(created)
        return created
    }

    public func deleteAgent(_ id: String) async throws {
        struct P: Encodable { var id: String }
        try await rpc().call("agents.delete", P(id: id))
        agents.removeAll { $0.id == id }
        threads[id] = nil
    }

    /// Load older history for an agent (the subscription only streams from `lastSeq`).
    public func loadHistory(_ agentId: String) async throws {
        struct P: Encodable { var after: Int64; var limit: Int; var agentId: String }
        let events = try await rpc().call("events.since", P(after: 0, limit: 2000, agentId: agentId), as: [Event].self)
        var t = AgentThread()
        for e in events { t.apply(e) }
        // Keep live state that arrived after the history page.
        if let live = threads[agentId], live.lastSeq > t.lastSeq {
            for item in live.items where !t.items.contains(where: { $0.id == item.id }) { t.items.append(item) }
            t.status = live.status
            t.lastSeq = live.lastSeq
        }
        threads[agentId] = t
    }
}

extension Event: Encodable {
    // Only needed so `[Event]` satisfies generic constraints in tests; never sent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }
}
