import Foundation

// A DevTools session over one WebSocket: calls matched to answers by id, and events as a stream.

/// An event from the page (`Page.screencastFrame`, `Page.frameNavigated`…).
public struct CDPEvent: Sendable {
    public var method: String
    public var params: JSONValue
}

public enum CDPError: Error, Sendable, Equatable, LocalizedError {
    /// The browser answered with an error.
    case remote(code: Int, message: String)
    /// The socket closed before the answer.
    case closed
    /// The browser has no page to attach to.
    case noPage
    /// A message that is not DevTools JSON, or a route address that cannot be built.
    case badMessage
    /// A browser route answered with this status, and the status has no more specific case.
    case httpStatus(Int)
    /// The browser is not running on the server (`409 browser_not_running`).
    case browserNotRunning
    /// The tab is no longer open (`404 no_such_tab`).
    case noSuchTab
    /// This device already holds its DevTools sockets (`429`).
    case tooManySockets
    /// The server refused the device token (`401` or `403`).
    case unauthorized

    /// The error for a browser route that answered `status` instead of 200 or 101.
    static func routeError(status: Int) -> CDPError {
        switch status {
        case 401, 403: .unauthorized
        case 404: .noSuchTab
        case 409: .browserNotRunning
        case 429: .tooManySockets
        default: .httpStatus(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .remote(_, let message): message
        case .closed: "the browser connection closed"
        case .noPage: "the browser has no page"
        case .badMessage: "the browser sent an unreadable message"
        case .httpStatus(let code): "the browser's server answered with HTTP \(code)"
        case .browserNotRunning: "the browser is not running"
        case .noSuchTab: "that tab is no longer open"
        case .tooManySockets: "this device already has its browser connections open"
        case .unauthorized: "the server refused this device's token"
        }
    }
}

/// The socket under a `CDPClient`. The app uses `URLSessionCDPSocket`; tests use a mock.
public protocol CDPSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text message. Throws when the socket is closed.
    func receive() async throws -> String
    func close() async
}

/// A `URLSessionWebSocketTask` that speaks text frames.
public actor URLSessionCDPSocket: CDPSocket {
    /// The largest message the app takes from the daemon: a screencast frame or a big answer. Chrome's own limit is 64 MiB.
    static let maxMessageSize = 64 * 1024 * 1024

    private let session: URLSession
    private let task: URLSessionWebSocketTask

    private init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    /// Opens the socket and waits for the upgrade. A refused upgrade throws `CDPError.routeError` for its
    /// HTTP status, so the caller learns why (409, 404, 429) instead of a silent close.
    public static func open(request: URLRequest) async throws -> URLSessionCDPSocket {
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maxMessageSize
        task.resume()
        do {
            // A ping completes once the upgrade has succeeded, and fails with the handshake error otherwise.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            session.invalidateAndCancel()
            if let status, status != 101 { throw CDPError.routeError(status: status) }
            throw CDPError.closed
        }
        return URLSessionCDPSocket(session: session, task: task)
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        while true {
            switch try await task.receive() {
            case .string(let text):
                return text
            case .data(let data):
                return String(decoding: data, as: UTF8.self)
            @unknown default:
                continue
            }
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

public actor CDPClient {
    /// Events from the page, in arrival order. Never drops: a slow consumer only delays itself.
    public nonisolated let events: AsyncStream<CDPEvent>
    private let eventSink: AsyncStream<CDPEvent>.Continuation
    private let socket: CDPSocket
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false

    /// Starts reading at once.
    public init(socket: CDPSocket) {
        self.socket = socket
        (events, eventSink) = AsyncStream.makeStream(of: CDPEvent.self, bufferingPolicy: .unbounded)
        Task { await self.readLoop() }
    }

    /// Sends `command` and returns the page's `result`. Throws `CDPError.remote` when the browser answers with an error.
    public func send(_ command: CDPCommand) async throws -> JSONValue {
        guard !closed else { throw CDPError.closed }
        let id = nextId
        nextId += 1
        let text = CDP.encode(id: id, command: command)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            pending[id] = continuation
            Task {
                do {
                    try await self.socket.send(text)
                } catch {
                    self.fail(id, with: error)
                }
            }
        }
    }

    /// Closes the socket. Calls still waiting throw `CDPError.closed`.
    public func close() async {
        guard !closed else { return }
        closed = true
        await socket.close()
        failAll(CDPError.closed)
        eventSink.finish()
    }

    /// Feeds one text message as if the socket had read it. The read loop does this for every message.
    func handle(_ text: String) {
        guard let message = try? CDP.parse(text) else { return }
        switch message {
        case .response(let id, let result):
            pending.removeValue(forKey: id)?.resume(returning: result)
        case .error(let id, let code, let errorMessage):
            pending.removeValue(forKey: id)?.resume(throwing: CDPError.remote(code: code, message: errorMessage))
        case .event(let method, let params):
            eventSink.yield(CDPEvent(method: method, params: params))
        }
    }

    private func readLoop() async {
        while !closed {
            do {
                let text = try await socket.receive()
                handle(text)
            } catch {
                break
            }
        }
        closed = true
        failAll(CDPError.closed)
        eventSink.finish()
    }

    private func fail(_ id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }
}
