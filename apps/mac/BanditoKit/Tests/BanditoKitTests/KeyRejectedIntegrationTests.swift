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
}
