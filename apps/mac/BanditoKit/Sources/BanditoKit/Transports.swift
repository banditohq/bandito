import Foundation
import Network

/// WebSocket to `/v1/rpc` with an optional device token.
public final class WebSocketTransport: RPCTransport, @unchecked Sendable {
    private let url: URL
    private let token: String?
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(url: URL, token: String?) {
        self.url = url
        self.token = token
        self.session = URLSession(configuration: .ephemeral)
    }

    public func connect() async throws {
        var req = URLRequest(url: url)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 16 << 20
        task = t
        t.resume()
    }

    public func send(_ text: String) async throws {
        guard let task else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        guard let task else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(decoding: d, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

/// The daemon's unix socket (this Mac): newline-delimited JSON-RPC, no token.
public actor UnixSocketTransport: RPCTransport {
    private let path: String
    private var conn: NWConnection?
    private var buffer = Data()

    public init(path: String) {
        self.path = path
    }

    public func connect() async throws {
        let c = NWConnection(to: .unix(path: path), using: .tcp)
        conn = c
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = Once()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { k.resume() }
                case .failed(let e), .waiting(let e): once.run { k.resume(throwing: e) }
                case .cancelled:
                    once.run { k.resume(throwing: RPCError(code: RPCError.disconnected, message: "cancelled")) }
                default: break
                }
            }
            c.start(queue: .global(qos: .userInitiated))
        }
    }

    public func send(_ text: String) async throws {
        guard let conn else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        let data = Data((text + "\n").utf8)
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            conn.send(
                content: data,
                completion: .contentProcessed { err in
                    if let err { k.resume(throwing: err) } else { k.resume() }
                })
        }
    }

    public func receive() async throws -> String {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.isEmpty { continue }
                return String(decoding: line, as: UTF8.self)
            }
            guard let conn else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
            let chunk: Data = try await withCheckedThrowingContinuation { k in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, err in
                    if let err { k.resume(throwing: err) }
                    else if let data, !data.isEmpty { k.resume(returning: data) }
                    else if done { k.resume(throwing: RPCError(code: RPCError.disconnected, message: "closed")) }
                    else { k.resume(returning: Data()) }
                }
            }
            buffer.append(chunk)
        }
    }

    public func close() async {
        conn?.cancel()
        conn = nil
    }
}

/// Runs a closure at most once (for continuation callbacks that may fire repeatedly).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ f: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if done { return }
        done = true
        f()
    }
}
