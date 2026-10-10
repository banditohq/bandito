import Foundation
import Network
import Testing

@testable import BanditoKit

/// A loopback HTTP server that answers every request, WebSocket upgrades included, with a fixed status line and no
/// body — what the daemon does for a token it does not know (`daemon/src/rpc/ws.rs`: 401 "unknown or revoked token").
private final class RefusingServer: @unchecked Sendable {
    // @unchecked: `connections` is touched on `queue` only.
    private let queue = DispatchQueue(label: "refusing-server")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    let status: String

    /// Starts on a free loopback port; `port` is ready when this returns.
    init(status: String) async throws {
        self.status = status
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let reply = "HTTP/1.1 \(self.status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { k.resume() }
                case .failed(let error): once.run { k.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var url: URL { URL(string: "ws://127.0.0.1:\(listener.port?.rawValue ?? 0)/v1/rpc")! }

    func stop() {
        listener.cancel()
        queue.async { self.connections.forEach { $0.cancel() } }
    }
}

@Suite(.serialized) struct KeyRejectedIntegrationTests {
    @Test func aServerThatAnswers401IsAKeyRejectionNotSilence() async throws {
        let server = try await RefusingServer(status: "401 Unauthorized")
        defer { server.stop() }
        let client = RPCClient(transport: WebSocketTransport(url: server.url, token: "bdt_unknown"))
        try await client.start()
        do {
            try await client.call("daemon.info", [String: String](), timeout: .seconds(10))
            Issue.record("expected the call to fail")
        } catch let error as RPCError {
            #expect(error.code == RPCError.keyRejected)
            #expect(FailureKind.classify(error) == .keyRejected)
        }
        await client.close()
    }

    @Test func aForbiddenHandshakeIsAKeyRejectionToo() async throws {
        let server = try await RefusingServer(status: "403 Forbidden")
        defer { server.stop() }
        let client = RPCClient(transport: WebSocketTransport(url: server.url, token: "bdt_unknown"))
        try await client.start()
        do {
            try await client.call("daemon.info", [String: String](), timeout: .seconds(10))
            Issue.record("expected the call to fail")
        } catch let error as RPCError {
            #expect(error.code == RPCError.keyRejected)
        }
        await client.close()
    }

    @MainActor
    @Test func aServerModelStopsAtKeyRejectedAndDoesNotRetry() async throws {
        let server = try await RefusingServer(status: "401 Unauthorized")
        defer { server.stop() }
        let model = ServerModel(
            config: ServerConfig(name: "x", endpoint: .webSocket(url: server.url), token: "bdt_unknown"))
        var seen: [ConnectionState] = []
        model.onStateChange = { seen.append($0) }
        await model.connect()
        #expect(model.state == .failed(.keyRejected))
        // Not "reconnecting": a refused key is refused again.
        #expect(!seen.contains { if case .reconnecting = $0 { true } else { false } })
        await model.disconnect()
    }

    @Test func aServerThatIsNotThereStaysNoAnswer() async throws {
        // A port nothing listens on: bind one, read its number, close it.
        let probe = try await RefusingServer(status: "401 Unauthorized")
        let url = probe.url
        probe.stop()
        try await Task.sleep(for: .milliseconds(200))
        let client = RPCClient(transport: WebSocketTransport(url: url, token: "bdt_any"))
        try await client.start()
        do {
            try await client.call("daemon.info", [String: String](), timeout: .seconds(10))
            Issue.record("expected the call to fail")
        } catch {
            #expect(FailureKind.classify(error) == .noAnswer)
        }
        await client.close()
    }

    @Test func thePlainStatusRulesAreNarrow() {
        #expect(WebSocketTransport.rejection(forStatus: 401)?.code == RPCError.keyRejected)
        #expect(WebSocketTransport.rejection(forStatus: 403)?.code == RPCError.keyRejected)
        #expect(WebSocketTransport.rejection(forStatus: 421) == nil)
        #expect(WebSocketTransport.rejection(forStatus: 500) == nil)
        #expect(WebSocketTransport.rejection(forStatus: 101) == nil)
        #expect(WebSocketTransport.rejection(forStatus: nil) == nil)
    }

    // MARK: reconnecting after a refused key

    /// The first connection works; the next `rejected` ones are refused (keyRejected); every later one works.
    @MainActor
    private func model(isThisMac: Bool, rejected: Int, attempts: AttemptCounter) -> ServerModel {
        let url = isThisMac ? "ws://127.0.0.1:17777/v1/rpc" : "wss://srv.example.ts.net/v1/rpc"
        return ServerModel(
            config: ServerConfig(name: "x", endpoint: .webSocket(url: URL(string: url)!), token: "t", isThisMac: isThisMac),
            makeTransport: { _ in
                let n = attempts.next()
                if n >= 2, n < 2 + rejected { return RejectingTransport() }
                return n == 1 ? attempts.first : FakeTransport(handlers: daemonHandlers())
            },
            reconnectDelay: { _ in .milliseconds(10) })
    }

    @MainActor
    @Test func aRemoteServerKeepsRetryingAndShowsTheRefusalUntilItConnects() async throws {
        let attempts = AttemptCounter()
        let model = model(isThisMac: false, rejected: 3, attempts: attempts)
        await model.connect()
        await attempts.first.dropConnection()

        try await eventually { model.refusesKey }
        // It did not give up: after the refusals the next attempt connected, and the refusal is gone.
        try await eventually { model.state == .connected }
        #expect(attempts.count >= 5)
        #expect(!model.refusesKey)
        await model.disconnect()
    }

    @MainActor
    @Test func thisMacsOwnDaemonStopsAtTheFirstRefusal() async throws {
        let attempts = AttemptCounter()
        let model = model(isThisMac: true, rejected: 3, attempts: attempts)
        await model.connect()
        await attempts.first.dropConnection()

        try await eventually { model.state == .failed(.keyRejected) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(attempts.count == 2)
        #expect(model.refusesKey)
        await model.disconnect()
    }
}

private struct RejectingTransport: RPCTransport {
    func connect() async throws {
        throw RPCError(code: RPCError.keyRejected, message: "rejected")
    }
    func send(_ text: String) async throws {}
    func receive() async throws -> String { throw RPCError(code: RPCError.keyRejected, message: "rejected") }
    func close() async {}
}

// @unchecked: `n` is guarded by `lock`.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    let first = FakeTransport(handlers: daemonHandlers())
    var count: Int { lock.withLock { n } }
    func next() -> Int { lock.withLock { n += 1; return n } }
}
