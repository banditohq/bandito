import Foundation
import Network
import Testing

@testable import BanditoKit

/// A byte channel the test drives: `push` feeds what the peer sends, `written` shows what the code wrote.
actor MockChannel: ByteChannel {
    /// Reads from the feed one chunk at a time. The relay is the only reader.
    private final class Feed: @unchecked Sendable {
        var iterator: AsyncStream<Data>.AsyncIterator
        init(_ iterator: AsyncStream<Data>.AsyncIterator) { self.iterator = iterator }
        func next() async -> Data? { await iterator.next() }
    }

    private let feed: Feed
    private let inbound: AsyncStream<Data>.Continuation
    private(set) var written: [Data] = []
    private(set) var closed = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        feed = Feed(stream.makeAsyncIterator())
        inbound = continuation
    }

    func read() async throws -> Data? {
        await feed.next()
    }

    func write(_ data: Data) async throws {
        written.append(data)
    }

    func close() async {
        closed = true
        inbound.finish()
    }

    /// The peer sends `data`.
    func push(_ data: Data) {
        inbound.yield(data)
    }

    /// The peer finishes (end of stream).
    func peerFinished() {
        inbound.finish()
    }

    var writtenBytes: Data {
        written.reduce(into: Data()) { $0.append($1) }
    }
}

@MainActor
@Suite struct TunnelTests {
    // MARK: relay

    @Test func relayCopiesBytesBothWays() async throws {
        let local = MockChannel()
        let remote = MockChannel()
        let relay = Task { await TunnelRelay.run(local, remote) }

        await local.push(Data("ping".utf8))
        await remote.push(Data("pong".utf8))

        try await eventually { await remote.writtenBytes == Data("ping".utf8) }
        try await eventually { await local.writtenBytes == Data("pong".utf8) }
        await local.peerFinished()
        await relay.value
    }

    @Test func oneSideEndingClosesTheOther() async throws {
        let local = MockChannel()
        let remote = MockChannel()
        let relay = Task { await TunnelRelay.run(local, remote) }

        await local.push(Data("bye".utf8))
        await local.peerFinished()
        await relay.value

        #expect(await remote.writtenBytes == Data("bye".utf8))
        #expect(await local.closed)
        #expect(await remote.closed)
    }

    @Test func remoteEndingClosesTheLocalSide() async throws {
        let local = MockChannel()
        let remote = MockChannel()
        let relay = Task { await TunnelRelay.run(local, remote) }

        await remote.peerFinished()
        await relay.value

        #expect(await local.closed)
        #expect(await remote.closed)
    }

    // MARK: forwarder

    @Test func forwarderRelaysALocalConnectionToTheRemoteChannel() async throws {
        let remote = MockChannel()
        let forwarder = PortForwarder(makeRemote: { remote })
        let port = try await forwarder.localPort()
        #expect(port > 0)
        #expect(try await forwarder.localPort() == port)

        let client = NWConnection(
            host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
        try await connect(client)
        client.send(content: Data("ping".utf8), completion: .contentProcessed { _ in })

        try await eventually { await remote.writtenBytes == Data("ping".utf8) }
        await remote.push(Data("pong".utf8))
        #expect(try await receiveExactly(client, count: 4) == Data("pong".utf8))

        client.cancel()
        try await eventually { await remote.closed }
        await forwarder.stop()
    }

    @Test func remoteAddressWithTokenOutsideTLSOrLoopbackIsRefused() {
        #expect(throws: RPCError.self) {
            _ = try PortForwarder(
                tunnelURL: URL(string: "ws://192.168.1.20:7878/v1/tunnel?port=3000")!, token: "secret")
        }
    }

    // MARK: ServerModel.forward

    @Test func forwardOnThisMacIsDirectWithoutAForwarder() async throws {
        let (model, _) = makeModel([])

        #expect(try await model.forward(port: 3000) == URL(string: "http://127.0.0.1:3000"))
        #expect(model.forwarders.isEmpty)
    }

    @Test func forwardRejectsPortsOutOfRange() async throws {
        let (model, _) = makeModel([])
        await #expect(throws: RPCError.self) { _ = try await model.forward(port: 0) }
        await #expect(throws: RPCError.self) { _ = try await model.forward(port: 70_000) }
    }

    @Test func forwardToRemoteServerOpensOneLocalPortPerRemotePort() async throws {
        let (model, _) = makeModel(
            config: ServerConfig(
                name: "tunnel", endpoint: .webSocket(url: URL(string: "ws://127.0.0.1:7878/v1/rpc")!), token: "tok"),
            [])

        let first = try await model.forward(port: 3000)
        let again = try await model.forward(port: 3000)

        #expect(first == again)
        #expect(first.host() == "127.0.0.1")
        #expect((first.port ?? 0) > 0)
        #expect(model.forwarders.count == 1)
        await model.disconnect()
        #expect(model.forwarders.isEmpty)
    }

    @Test func forwardToLANServerWithTokenIsRefused() async throws {
        let (model, _) = makeModel(
            config: ServerConfig(
                name: "lan", endpoint: .webSocket(url: URL(string: "ws://192.168.1.20:7878/v1/rpc")!), token: "tok"),
            [])

        await #expect(throws: RPCError.self) { _ = try await model.forward(port: 3000) }
        #expect(model.forwarders.isEmpty)
    }
}
