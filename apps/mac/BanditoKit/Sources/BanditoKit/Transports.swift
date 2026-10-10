import Foundation
import Network

/// WebSocket to `/v1/rpc` with an optional device token. Single use: create one per connection.
public actor WebSocketTransport: RPCTransport {
    private let url: URL
    private let token: String?
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(url: URL, token: String?) {
        self.url = url
        self.token = token
        self.session = URLSession(configuration: .ephemeral)
    }

    /// The device token may only travel over TLS or to this Mac's own loopback address.
    static func allowsToken(for url: URL) -> Bool {
        if url.scheme?.lowercased() == "wss" { return true }
        let host = (url.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["127.0.0.1", "::1", "localhost"].contains(host)
    }

    public func connect() async throws {
        if token != nil, !Self.allowsToken(for: url) {
            throw RPCError(
                code: RPCError.insecureTransport,
                message: "refusing to send the device token over an unencrypted connection")
        }
        var req = URLRequest(url: url)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 16 << 20
        task = t
        t.resume()
    }

    /// The error for a handshake the server answered with this HTTP status: `keyRejected` for 401 and 403 (the daemon
    /// is there and refuses the device token), nil for anything else.
    static func rejection(forStatus status: Int?) -> RPCError? {
        guard let status, status == 401 || status == 403 else { return nil }
        return RPCError(code: RPCError.keyRejected, message: "the server rejected the device key (HTTP \(status))")
    }

    /// A failed handshake shows up as `NSURLErrorBadServerResponse` (-1011) on the first send or receive. The HTTP
    /// answer is on the task: a 401/403 there means the server answered and refused the key, which is not "no answer".
    private func mapped(_ error: Error, of task: URLSessionWebSocketTask) -> Error {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        return Self.rejection(forStatus: status) ?? error
    }

    public func send(_ text: String) async throws {
        guard let task else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        do {
            try await task.send(.string(text))
        } catch {
            throw mapped(error, of: task)
        }
    }

    public func receive() async throws -> String {
        guard let task else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        do {
            switch try await task.receive() {
            case .string(let s): return s
            case .data(let d): return String(decoding: d, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            throw mapped(error, of: task)
        }
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session.invalidateAndCancel()
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
// @unchecked: `done` is guarded by `lock`.
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
