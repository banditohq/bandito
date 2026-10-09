import Foundation

/// A bidirectional text channel to the daemon (one JSON-RPC message per call).
public protocol RPCTransport: Sendable {
    func connect() async throws
    func send(_ text: String) async throws
    /// The next message. Throws when the connection is closed.
    func receive() async throws -> String
    func close() async
}

public struct RPCError: Error, Sendable, Equatable, LocalizedError {
    public var code: Int
    public var message: String

    public var errorDescription: String? { message }

    public static let unauthorized = -32001
    public static let rateLimited = -32002
    public static let invalidParams = -32602
    /// Client-side: the connection closed before an answer.
    public static let disconnected = -1
}

/// JSON-RPC 2.0 client: matches responses to requests and turns `event`
/// notifications into an async stream.
public actor RPCClient {
    private let transport: RPCTransport
    private var nextId = 1
    private var waiting: [Int: CheckedContinuation<Data, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var closed = false

    /// Live events (`event` notifications) in arrival order.
    public nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public init(transport: RPCTransport) {
        self.transport = transport
        (events, eventSink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(10_000))
    }

    public func start() async throws {
        try await transport.connect()
        readTask = Task { await self.readLoop() }
    }

    public func close() async {
        closed = true
        readTask?.cancel()
        await transport.close()
        failAll()
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                let text = try await transport.receive()
                handle(text)
            } catch {
                break
            }
        }
        failAll()
    }

    private func failAll() {
        let pending = waiting
        waiting.removeAll()
        for (_, c) in pending {
            c.resume(throwing: RPCError(code: RPCError.disconnected, message: "disconnected from the server"))
        }
        eventSink.finish()
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let method = obj["method"] as? String {
            guard method == "event", let params = obj["params"],
                let pdata = try? JSONSerialization.data(withJSONObject: params),
                let ev = try? Self.decoder.decode(Event.self, from: pdata)
            else { return }
            eventSink.yield(ev)
            return
        }
        guard let id = (obj["id"] as? NSNumber)?.intValue, let c = waiting.removeValue(forKey: id) else { return }
        if let err = obj["error"] as? [String: Any] {
            c.resume(
                throwing: RPCError(
                    code: (err["code"] as? NSNumber)?.intValue ?? 0, message: err["message"] as? String ?? "error"))
            return
        }
        let result = obj["result"] ?? NSNull()
        // Wrap so scalars and null survive JSONSerialization.
        let wrapped = (try? JSONSerialization.data(withJSONObject: ["r": result])) ?? Data("{\"r\":null}".utf8)
        c.resume(returning: wrapped)
    }

    /// Call `method` and decode its result.
    public func call<R: Decodable>(_ method: String, _ params: some Encodable, as: R.Type = R.self) async throws -> R {
        if closed { throw RPCError(code: RPCError.disconnected, message: "disconnected from the server") }
        let id = nextId
        nextId += 1
        let paramsJSON = try Self.encoder.encode(params)
        let paramsString = String(decoding: paramsJSON, as: UTF8.self)
        let request = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\(jsonString(method)),\"params\":\(paramsString)}"
        let data: Data = try await withCheckedThrowingContinuation { c in
            waiting[id] = c
            Task {
                do {
                    try await self.transport.send(request)
                } catch {
                    self.fail(id, error)
                }
            }
        }
        return try Self.decoder.decode(ResultBox<R>.self, from: data).r
    }

    /// Call a method whose result the caller doesn't need.
    public func call(_ method: String, _ params: some Encodable) async throws {
        _ = try await call(method, params, as: JSONValue.self)
    }

    private func fail(_ id: Int, _ error: Error) {
        waiting.removeValue(forKey: id)?.resume(throwing: error)
    }

    private nonisolated func jsonString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct ResultBox<T: Decodable>: Decodable {
    var r: T
}

/// Empty params: `{}`.
public struct NoParams: Encodable, Sendable {
    public init() {}
}
