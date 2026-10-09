import Foundation
import Network

/// One side of a tunnel: a local TCP connection or a WebSocket.
protocol ByteChannel: Sendable {
    /// The next chunk from the peer, or nil when the peer has finished sending.
    func read() async throws -> Data?
    func write(_ data: Data) async throws
    /// Tells the peer that nothing more will be written (half-close). A no-op where the
    /// transport has no half-close, such as the WebSocket of the daemon's tunnel.
    func finishWrite() async
    /// Closes this side. A read that is waiting returns nil or throws.
    func close() async
}

/// Copies bytes both ways between two channels.
///
/// The end of one direction (EOF from the source) half-closes the destination's write side and the
/// other direction keeps running, so a response still arrives after the client finished its request.
/// An error on either side closes both. When both directions have ended, both sides are closed.
enum TunnelRelay {
    static func run(_ a: ByteChannel, _ b: ByteChannel) async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await pump(from: a, to: b) }
            group.addTask { await pump(from: b, to: a) }
            // `false` means that direction failed: closing both sides unblocks the other direction's read.
            for await ok in group where !ok {
                await a.close()
                await b.close()
            }
        }
        await a.close()
        await b.close()
    }

    /// Returns true on a clean end of the source, false on an error.
    private static func pump(from source: ByteChannel, to destination: ByteChannel) async -> Bool {
        while true {
            let chunk: Data?
            do {
                chunk = try await source.read()
            } catch {
                return false
            }
            guard let chunk else {
                await destination.finishWrite()
                return true
            }
            do {
                try await destination.write(chunk)
            } catch {
                return false
            }
        }
    }
}

/// A local TCP connection on this Mac, read and written through Network.framework.
// @unchecked: the only state is the NWConnection, used through its own thread-safe API (receive, send, cancel).
final class TCPChannel: ByteChannel, @unchecked Sendable {
    private let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func read() async throws -> Data? {
        while true {
            let chunk: Data? = try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, isComplete, error in
                    if let error {
                        k.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        k.resume(returning: data)
                    } else if isComplete {
                        k.resume(returning: nil)
                    } else {
                        // Nothing yet: an empty marker, so the loop reads again.
                        k.resume(returning: Data())
                    }
                }
            }
            guard let chunk else { return nil }
            if !chunk.isEmpty { return chunk }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { k.resume(throwing: error) } else { k.resume() }
                })
        }
    }

    /// Sends the FIN: the client sees end of stream, and can still send nothing more but may read.
    func finishWrite() async {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    func close() async {
        connection.cancel()
    }
}

/// A WebSocket that carries raw bytes as binary messages (the daemon's `/v1/tunnel`).
actor WebSocketByteChannel: ByteChannel {
    private let task: URLSessionWebSocketTask

    /// Opens the socket: the task starts at once.
    init(request: URLRequest, session: URLSession) {
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func read() async throws -> Data? {
        while true {
            switch try await task.receive() {
            case .data(let data):
                return data
            case .string:
                // The daemon sends only binary messages; text is ignored.
                continue
            @unknown default:
                continue
            }
        }
    }

    func write(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    /// No-op: the daemon's tunnel has no half-close. The socket stays open until the target ends.
    func finishWrite() async {}

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Makes one loopback TCP port on this Mac reach `127.0.0.1:<remote port>` on a WebSocket server.
/// Each accepted TCP connection gets its own `/v1/tunnel` WebSocket.
///
/// By default (`oneShot`) the forwarder accepts exactly one connection and closes its listener at once.
/// A forwarder that stays open would let any local process connect to the loopback port and reach the
/// server with the device token. A one-shot forwarder serves a single client that the app starts itself.
public actor PortForwarder {
    /// Returned by calls made after `stop()`, and by a start that was overtaken by `stop()`.
    static let stoppedError = RPCError(code: RPCError.disconnected, message: "the port forwarder was stopped")

    private let makeRemote: @Sendable () -> ByteChannel
    private let session: URLSession
    private let oneShot: Bool
    private var listener: NWListener?
    private var startTask: Task<UInt16, Error>?
    /// Both sides of every live connection, so `stop()` can close them.
    private var live: [UUID: [ByteChannel]] = [:]
    private var acceptedOne = false
    /// Set by `stop()` and never cleared: a stopped forwarder does not start again.
    private var stopped = false

    /// - Parameters:
    ///   - tunnelURL: the server's `ws(s)://…/v1/tunnel?port=N`.
    ///   - token: the device token. It is sent only where `WebSocketTransport` allows tokens.
    ///   - oneShot: accept exactly one connection, then close the listener.
    public init(tunnelURL: URL, token: String?, oneShot: Bool = true) throws {
        var request = URLRequest(url: tunnelURL)
        if let token {
            guard WebSocketTransport.allowsToken(for: tunnelURL) else {
                throw RPCError(
                    code: RPCError.insecureTransport,
                    message: "refusing to send the device token over an unencrypted connection")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let session = URLSession(configuration: .ephemeral)
        // A copy: the closure below is @Sendable and cannot capture the `var`.
        let upgrade = request
        self.session = session
        self.oneShot = oneShot
        self.makeRemote = { WebSocketByteChannel(request: upgrade, session: session) }
    }

    /// Test seam: each accepted connection gets the channel `makeRemote` returns.
    init(makeRemote: @escaping @Sendable () -> ByteChannel, oneShot: Bool = true) {
        self.makeRemote = makeRemote
        self.session = URLSession(configuration: .ephemeral)
        self.oneShot = oneShot
    }

    /// The loopback port that the forwarder listens on. Starts the listener on first use.
    public func localPort() async throws -> UInt16 {
        if stopped { throw Self.stoppedError }
        if let startTask {
            return try await startTask.value
        }
        let task = Task { try await self.startListener() }
        startTask = task
        do {
            return try await task.value
        } catch {
            startTask = nil
            throw error
        }
    }

    /// Stops listening and closes every live connection. Pending `localPort()` calls throw.
    public func stop() async {
        stopped = true
        startTask?.cancel()
        startTask = nil
        listener?.cancel()
        listener = nil
        let channels = live.values.flatMap { $0 }
        live.removeAll()
        for channel in channels {
            await channel.close()
        }
        session.invalidateAndCancel()
    }

    /// Number of connections being relayed right now.
    var liveConnectionCount: Int {
        live.count
    }

    private func startListener() async throws -> UInt16 {
        guard !stopped else { throw Self.stoppedError }
        // Only the loopback interface: other machines cannot reach the port.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        once.run { k.resume(returning: port) }
                    }
                case .failed(let error):
                    once.run { k.resume(throwing: error) }
                case .cancelled:
                    // stop() cancelled the listener, possibly while a start was waiting for `.ready`.
                    once.run { k.resume(throwing: Self.stoppedError) }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Relays one accepted connection. A connection that arrives after `stop()`, or a second one for a
    /// one-shot forwarder, is refused at once and nothing is recorded for it.
    func accept(_ connection: NWConnection) {
        guard !stopped, !(oneShot && acceptedOne) else {
            connection.cancel()
            return
        }
        acceptedOne = true
        if oneShot {
            listener?.cancel()
            listener = nil
        }
        let id = UUID()
        let local = TCPChannel(connection)
        let remote = makeRemote()
        live[id] = [local, remote]
        connection.start(queue: .global(qos: .userInitiated))
        Task {
            await TunnelRelay.run(local, remote)
            self.finished(id)
        }
    }

    private func finished(_ id: UUID) {
        live[id] = nil
    }
}
