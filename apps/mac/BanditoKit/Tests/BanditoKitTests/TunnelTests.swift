import Foundation
import Network
import Testing

@testable import BanditoKit

/// A byte channel the test drives. `push` feeds what the peer sends; `peerFinished` ends the peer's
/// side, `fail` makes its next read throw. `written` and `writeFinished` show what the code did.
actor MockChannel: ByteChannel {
    /// Reads from the feed one chunk at a time. The relay is the only reader.
    // @unchecked: the iterator is only advanced by the relay's single pending read.
    private final class Feed: @unchecked Sendable {
        var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator
        init(_ iterator: AsyncThrowingStream<Data, Error>.AsyncIterator) { self.iterator = iterator }
        func next() async throws -> Data? { try await iterator.next() }
    }

    enum Failure: Error { case peer }

    private let feed: Feed
    private let inbound: AsyncThrowingStream<Data, Error>.Continuation
    private(set) var written: [Data] = []
    private(set) var writeFinished = false
    private(set) var closed = false

    init() {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        feed = Feed(stream.makeAsyncIterator())
        inbound = continuation
    }

    func read() async throws -> Data? {
        try await feed.next()
    }

    func write(_ data: Data) async throws {
        written.append(data)
    }

    func finishWrite() async {
        writeFinished = true
    }

    func close() async {
        closed = true
        inbound.finish()
    }

    /// The peer sends `data`.
    func push(_ data: Data) {
        inbound.yield(data)
    }

    /// The peer ends its side (end of stream).
    func peerFinished() {
        inbound.finish()
    }

    /// The peer's side fails: the next read throws.
    func fail() {
        inbound.finish(throwing: Failure.peer)
    }

    var writtenBytes: Data {
        written.reduce(into: Data()) { $0.append($1) }
    }
}

/// Counts calls from a `@Sendable` closure.
// @unchecked: `count` is guarded by `lock`.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

/// The result of `task`, or nil if it did not finish within `timeout`.
func finished<T: Sendable>(_ task: Task<T, Error>, within timeout: Duration = .seconds(3)) async -> Result<T, Error>? {
    await withTaskGroup(of: Result<T, Error>?.self) { group in
        group.addTask { await task.result }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
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
        await remote.peerFinished()
        await relay.value
    }

    @Test func endOfOneSideHalfClosesTheOtherAndKeepsItsOwnWayOpen() async throws {
        let local = MockChannel()
        let remote = MockChannel()
        let relay = Task { await TunnelRelay.run(local, remote) }

        await local.push(Data("request".utf8))
        await local.peerFinished()

        try await eventually { await remote.writeFinished }
        #expect(await remote.writtenBytes == Data("request".utf8))
        #expect(await remote.closed == false)

        // The response still arrives after the request's end of stream.
        await remote.push(Data("response".utf8))
        try await eventually { await local.writtenBytes == Data("response".utf8) }
        #expect(await local.closed == false)

        await remote.peerFinished()
        await relay.value
        #expect(await local.writeFinished)
        #expect(await local.closed)
        #expect(await remote.closed)
    }

    @Test func remoteEndingHalfClosesTheLocalSide() async throws {
        let local = MockChannel()
        let remote = MockChannel()
        let relay = Task { await TunnelRelay.run(local, remote) }

        await remote.peerFinished()
        try await eventually { await local.writeFinished }
        #expect(await local.closed == false)

        await local.peerFinished()
        await relay.value
        #expect(await local.closed)
        #expect(await remote.closed)
    }

    @Test func errorOnEitherSideClosesBothSides() async throws {
        let local = MockChannel()
        let remote = MockChannel()
        let relay = Task { await TunnelRelay.run(local, remote) }

        await local.fail()
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

        // The client's close is a half-close toward the remote; the remote side ends when the target does.
        client.cancel()
        try await eventually { await remote.writeFinished }
        await remote.peerFinished()
        try await eventually { await remote.closed }
        await forwarder.stop()
    }

    @Test func clientEndOfRequestStillReceivesTheResponse() async throws {
        let remote = MockChannel()
        let forwarder = PortForwarder(makeRemote: { remote })
        let port = try await forwarder.localPort()
        let client = NWConnection(
            host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
        try await connect(client)

        // The request, then the client's FIN.
        client.send(content: Data("request".utf8), completion: .contentProcessed { _ in })
        client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)

        try await eventually { await remote.writeFinished }
        #expect(await remote.writtenBytes == Data("request".utf8))
        await remote.push(Data("response".utf8))
        #expect(try await receiveExactly(client, count: 8) == Data("response".utf8))

        await remote.peerFinished()
        try await eventually { await remote.closed }
        client.cancel()
        await forwarder.stop()
    }

    @Test func stopWhileStartingFailsPendingLocalPortCalls() async throws {
        let forwarder = PortForwarder(makeRemote: { MockChannel() })
        let pending = Task { try await forwarder.localPort() }

        await forwarder.stop()

        let result = try #require(await finished(pending))
        #expect(throws: RPCError.self) { try result.get() }
        await #expect(throws: RPCError.self) { _ = try await forwarder.localPort() }
    }

    @Test func connectionAfterStopIsRefusedAndNotRecorded() async throws {
        let calls = CallCounter()
        let forwarder = PortForwarder(makeRemote: {
            calls.bump()
            return MockChannel()
        })
        _ = try await forwarder.localPort()
        await forwarder.stop()

        // A connection that reaches accept() after stop() is cancelled at once.
        let late = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        await forwarder.accept(late)

        #expect(calls.value == 0)
        #expect(await forwarder.liveConnectionCount == 0)
    }

    @Test func oneShotForwarderAcceptsExactlyOneConnection() async throws {
        let remote = MockChannel()
        let calls = CallCounter()
        let forwarder = PortForwarder(makeRemote: {
            calls.bump()
            return remote
        })
        let port = try await forwarder.localPort()

        let first = NWConnection(
            host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
        try await connect(first)
        // The kernel may complete a second handshake in the backlog before the listener closes, so only
        // the relay counts: a second connection must never get a remote channel.
        let second = NWConnection(
            host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
        second.start(queue: .global())
        try await Task.sleep(for: .milliseconds(300))
        second.cancel()
        #expect(calls.value == 1)

        first.cancel()
        try await eventually { await remote.writeFinished }
        await remote.peerFinished()
        try await eventually { await remote.closed }
        await forwarder.stop()
    }

    @Test func remoteAddressWithTokenOutsideTLSOrLoopbackIsRefused() {
        #expect(throws: RPCError.self) {
            _ = try PortForwarder(
                tunnelURL: URL(string: "ws://192.168.1.20:7878/v1/tunnel?port=3000")!, token: "secret")
        }
    }

    // MARK: ServerModel.forwardOnce

    @Test func forwardOnceOnThisMacIsDirectWithoutAForwarder() async throws {
        let (model, _) = makeModel([])

        #expect(try await model.forwardOnce(port: 3000) == URL(string: "http://127.0.0.1:3000"))
        #expect(model.forwarders.isEmpty)
    }

    @Test func forwardOnceRejectsPortsOutOfRange() async throws {
        let (model, _) = makeModel([])
        await #expect(throws: RPCError.self) { _ = try await model.forwardOnce(port: 0) }
        await #expect(throws: RPCError.self) { _ = try await model.forwardOnce(port: 70_000) }
    }

    @Test func forwardOnceToRemoteServerMakesAFreshForwarderEachCall() async throws {
        let (model, _) = makeModel(
            config: ServerConfig(
                name: "tunnel", endpoint: .webSocket(url: URL(string: "ws://127.0.0.1:7878/v1/rpc")!), token: "tok"),
            [])

        let first = try await model.forwardOnce(port: 3000)
        let again = try await model.forwardOnce(port: 3000)

        #expect(first != again)
        #expect(first.host() == "127.0.0.1")
        #expect((first.port ?? 0) > 0)
        #expect(model.forwarders.count == 2)
        await model.disconnect()
        #expect(model.forwarders.isEmpty)
    }

    @Test func forwardOnceToLANServerWithTokenIsRefused() async throws {
        let (model, _) = makeModel(
            config: ServerConfig(
                name: "lan", endpoint: .webSocket(url: URL(string: "ws://192.168.1.20:7878/v1/rpc")!), token: "tok"),
            [])

        await #expect(throws: RPCError.self) { _ = try await model.forwardOnce(port: 3000) }
        #expect(model.forwarders.isEmpty)
    }
}
