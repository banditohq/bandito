import Foundation
import Testing

@testable import BanditoKit

/// In-memory `RPCTransport`. Records what the client sends and delivers what the test pushes.
/// With `autoRespond`, a request whose method has a handler is answered as soon as it is sent,
/// i.e. before `send` returns, like a fast daemon. That exercises the early-answer path.
actor FakeTransport: RPCTransport {
    /// Receives the request's params as JSON, returns the result as JSON.
    typealias Handler = @Sendable (String) -> String
    /// Receives the request's params as JSON; returns the error object (`{code, message, data}`)
    /// to answer with, or nil to fall through to the normal handler.
    typealias Failure = @Sendable (String) -> String?

    private let handlers: [String: Handler]
    private let errors: [String: Failure]
    private let autoRespond: Bool
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    /// The client's read loop is the only reader, so the iterator needs no further synchronization.
    private let inbound: InboundIterator
    private var sent: [String] = []
    /// What `httpBase` answers: an ssh tunnel's HTTP base in the tests that need one.
    private var base: URL?

    init(
        handlers: [String: Handler] = [:], errors: [String: Failure] = [:], autoRespond: Bool = true,
        httpBase: URL? = nil
    ) {
        self.handlers = handlers
        self.errors = errors
        self.autoRespond = autoRespond
        self.base = httpBase
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: String.self, throwing: Error.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.inbound = InboundIterator(stream.makeAsyncIterator())
    }

    func connect() async throws {}

    func send(_ text: String) async throws {
        sent.append(text)
        guard autoRespond, let request = JSONRPC.parse(text) else { return }
        if let failure = errors[request.method], let error = failure(request.paramsJSON) {
            continuation.yield(JSONRPC.errorResponse(id: request.id, error: error))
            return
        }
        guard let handler = handlers[request.method] else { return }
        continuation.yield(JSONRPC.response(id: request.id, result: handler(request.paramsJSON)))
    }

    func receive() async throws -> String {
        guard let line = try await inbound.next() else {
            throw RPCError(code: RPCError.disconnected, message: "fake transport closed")
        }
        return line
    }

    func close() async {
        continuation.finish()
    }

    var httpBase: URL? {
        get async { base }
    }

    // MARK: test controls

    /// Moves the tunnel: the next request is answered from the new base.
    func setHTTPBase(_ url: URL?) {
        base = url
    }

    /// Delivers a server message (a response or a notification).
    func push(_ text: String) {
        continuation.yield(text)
    }

    /// Ends the inbound stream, as if the connection dropped.
    func dropConnection() {
        continuation.finish()
    }

    func sentTexts() -> [String] {
        sent
    }
}

/// Holds the single-reader iterator outside the actor's isolation so it can be advanced across `await`.
// @unchecked: only the client's read loop advances the iterator.
private final class InboundIterator: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator

    init(_ iterator: AsyncThrowingStream<String, Error>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> String? {
        try await iterator.next()
    }
}

/// JSON-RPC helpers for building and reading test messages.
enum JSONRPC {
    struct Request {
        var id: Int
        var method: String
        var paramsJSON: String
    }

    static func parse(_ text: String) -> Request? {
        guard let data = text.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let id = (obj["id"] as? NSNumber)?.intValue,
            let method = obj["method"] as? String
        else { return nil }
        let params = obj["params"] ?? [String: Any]()
        let paramsJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: params)) ?? Data(), as: UTF8.self)
        return Request(id: id, method: method, paramsJSON: paramsJSON)
    }

    static func response(id: Int, result: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#
    }

    /// `error` is the JSON error object: `{"code":…,"message":…,"data":…}`.
    static func errorResponse(id: Int, error: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"error":\#(error)}"#
    }

    static func notification(_ event: String) -> String {
        #"{"jsonrpc":"2.0","method":"event","params":\#(event)}"#
    }

    /// A persisted `message.assistant` event whose timestamp equals its seq.
    static func messageEvent(seq: Int, agent: String = "a", text: String) -> String {
        #"{"seq":\#(seq),"agent_id":"\#(agent)","ts":\#(seq),"kind":"message.assistant","payload":{"text":"\#(text)"}}"#
    }

    /// Id of the first request with `method` among `texts`.
    static func id(of method: String, in texts: [String]) -> Int? {
        texts.compactMap(parse).first { $0.method == method }?.id
    }

    /// Raw texts of all requests with `method`.
    static func requests(of method: String, in texts: [String]) -> [String] {
        texts.filter { parse($0)?.method == method }
    }

    /// An integer param of a request, e.g. `after`.
    static func intParam(_ key: String, in text: String) -> Int? {
        guard let request = parse(text),
            let params = try? JSONSerialization.jsonObject(with: Data(request.paramsJSON.utf8)) as? [String: Any]
        else { return nil }
        return (params[key] as? NSNumber)?.intValue
    }
}

/// Polls `condition` until it holds (5 ms steps, 3 s at most).
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met within \(timeout)")
}
