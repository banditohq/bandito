import Foundation
import Network

/// One side of a tunnel: a local TCP connection or a WebSocket.
protocol ByteChannel: Sendable {
    /// The next chunk from the peer, or nil when the peer has finished.
    func read() async throws -> Data?
    func write(_ data: Data) async throws
    /// Closes this side. A read that is waiting returns nil or throws.
    func close() async
}

/// Copies bytes both ways between two channels. When one direction ends, both sides are closed.
enum TunnelRelay {
    static func run(_ a: ByteChannel, _ b: ByteChannel) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(from: a, to: b) }
            group.addTask { await pump(from: b, to: a) }
            _ = await group.next()
            // Closing both sides unblocks the other direction's pending read.
            await a.close()
            await b.close()
            await group.waitForAll()
        }
    }

    private static func pump(from source: ByteChannel, to destination: ByteChannel) async {
        while true {
            let chunk: Data?
            do {
                chunk = try await source.read()
            } catch {
                return
            }
            guard let chunk else { return }
            do {
                try await destination.write(chunk)
            } catch {
                return
            }
        }
    }
}

/// A local TCP connection on this Mac, read and written through Network.framework.
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

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Makes one loopback TCP port on this Mac reach `127.0.0.1:<remote port>` on a WebSocket
/// server. Each accepted TCP connection gets its own `/v1/tunnel` WebSocket.
public actor PortForwarder {
    private let makeRemote: @Sendable () -> ByteChannel
    private let session: URLSession
    private var listener: NWListener?
    private var startTask: Task<UInt16, Error>?
    /// Both sides of every live connection, so `stop()` can close them.
    private var live: [UUID: [ByteChannel]] = [:]

    /// - Parameters:
    ///   - tunnelURL: the server's `ws(s)://…/v1/tunnel?port=N`.
    ///   - token: the device token. It is sent only where `WebSocketTransport` allows tokens.
    public init(tunnelURL: URL, token: String?) throws {
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
        let upgrade = request
        self.session = session
        self.makeRemote = { WebSocketByteChannel(request: upgrade, session: session) }
    }

    /// Test seam: each accepted connection gets the channel `makeRemote` returns.
    init(makeRemote: @escaping @Sendable () -> ByteChannel) {
        self.makeRemote = makeRemote
        self.session = URLSession(configuration: .ephemeral)
    }

    /// The loopback port that the forwarder listens on. Starts the listener on first use.
    public func localPort() async throws -> UInt16 {
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

    /// Stops listening and closes every live connection.
    public func stop() async {
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

    private func startListener() async throws -> UInt16 {
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
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    private func accept(_ connection: NWConnection) {
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
