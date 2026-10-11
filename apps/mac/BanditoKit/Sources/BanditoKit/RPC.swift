import Foundation
import os

/// A bidirectional text channel to the daemon (one JSON-RPC message per call).
public protocol RPCTransport: Sendable {
    func connect() async throws
    func send(_ text: String) async throws
    /// The next message. Throws when the connection is closed.
    func receive() async throws -> String
    func close() async
    /// `http://127.0.0.1:<port>`, where the daemon's HTTP routes answer through this connection, or nil when it
    /// has none. Read at every request: a tunnel may have moved.
    var httpBase: URL? { get async }
}

extension RPCTransport {
    public var httpBase: URL? {
        get async { nil }
    }
}

public struct RPCError: Error, Sendable, Equatable, LocalizedError {
    public var code: Int
    public var message: String
    /// `error.data` from the daemon, when it sent one.
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }

    /// `data.reason` of a file or checkpoint error: `conflict`, `not_found`, `exists`, …
    public var reason: String? { data?["reason"]?.string }

    /// `data.etag` of a `conflict`: the file's current etag.
    public var etag: String? { data?["etag"]?.string }

    public static let unauthorized = -32001
    public static let rateLimited = -32002
    public static let invalidParams = -32602
    /// File operation failed; `data.reason` says why (see docs/ARCHITECTURE.md#files).
    public static let fileError = -32020
    /// Terminal operation failed; the message starts with the reason (`not_found: …`).
    public static let terminalError = -32021
    /// Checkpoint or git operation failed; `data.reason` says why.
    public static let changesError = -32022
    /// Host operation failed; `data.reason` is `forbidden`, `not_found` or `io`.
    public static let hostError = -32023
    /// Skill folder or file operation refused; `data.reason` says why (see docs/ARCHITECTURE.md#sharing).
    public static let commandsError = -32027
    /// Workspace operation failed; `data.reason` says why (see `WorkspaceFailure`).
    public static let workspaceError = -32028
    /// Client-side: the connection closed before an answer.
    public static let disconnected = -1
    /// Client-side: the server did not answer within the call's timeout.
    public static let timedOut = -2
    /// Client-side: refused to send a credential over an unencrypted connection.
    public static let insecureTransport = -3
    /// Client-side: this operation is not available for the server's connection kind yet.
    public static let unsupportedTransport = -4
    /// Client-side: the server answered the WebSocket handshake with 401 or 403 — it is there, and does not accept
    /// this device's key (the daemon lost its data, was reinstalled, or the device was revoked).
    public static let keyRejected = -5
}

/// A JSON-RPC notification other than `event` (for example `term.output`), with its raw params.
public struct RPCNotification: Sendable {
    public var method: String
    /// The `params` object as JSON. Decode it with `RPCClient.decoder`.
    public var params: Data

    public init(method: String, params: Data) {
        self.method = method
        self.params = params
    }
}

/// JSON-RPC 2.0 client: matches responses to requests and turns `event`
/// notifications into an async stream, and every other notification into `notifications`.
public actor RPCClient {
    /// Where one request's answer is at. Written before the request is sent, so an
    /// answer that arrives while the send is still suspended is not lost.
    private enum Slot {
        /// Request written or being written; no caller is suspended yet.
        case sent
        /// The caller is suspended and waiting for the answer.
        case waiting(CheckedContinuation<Data, Error>)
        /// The answer (or the timeout) arrived before the caller started waiting.
        case settled(Result<Data, Error>)
    }

    private static let log = Logger(subsystem: "dev.bandito", category: "rpc")

    private let transport: RPCTransport
    private let onDecodeFailure: (@Sendable () -> Void)?
    private var nextId = 1
    private var slots: [Int: Slot] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var readTask: Task<Void, Never>?
    private var closed = false
    /// Why the read loop ended, when the transport said it with a specific error (`keyRejected`). Pending and later
    /// calls fail with it instead of the plain `disconnected`.
    private var endError: RPCError?

    /// Event notifications that could not be decoded and were skipped.
    public private(set) var decodeFailures = 0

    /// Live events (`event` notifications) in arrival order. Never drops: a slow consumer
    /// only grows memory, and the daemon's `seq` lets the model detect any gap.
    public nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    /// Notifications other than `event`, such as `term.output`, in arrival order. Never drops either.
    public nonisolated let notifications: AsyncStream<RPCNotification>
    private let notificationSink: AsyncStream<RPCNotification>.Continuation

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

    /// - Parameter onDecodeFailure: called (on the actor) each time an event is skipped.
    public init(transport: RPCTransport, onDecodeFailure: (@Sendable () -> Void)? = nil) {
        self.transport = transport
        self.onDecodeFailure = onDecodeFailure
        (events, eventSink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        (notifications, notificationSink) = AsyncStream.makeStream(of: RPCNotification.self, bufferingPolicy: .unbounded)
    }

    public func start() async throws {
        try await transport.connect()
        readTask = Task { await self.readLoop() }
    }

    public func close() async {
        closed = true
        readTask?.cancel()
        readTask = nil
        await transport.close()
        failAll()
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                let text = try await transport.receive()
                handle(text)
            } catch {
                if let rpc = error as? RPCError, rpc.code == RPCError.keyRejected { endError = rpc }
                break
            }
        }
        failAll()
    }

    /// Ends every pending call with `disconnected` and finishes the event stream.
    private func failAll() {
        closed = true
        let pending = slots
        slots.removeAll()
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        let error = endError ?? RPCError(code: RPCError.disconnected, message: "disconnected from the server")
        for (_, slot) in pending {
            if case .waiting(let c) = slot { c.resume(throwing: error) }
        }
        eventSink.finish()
        notificationSink.finish()
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            Self.log.error("dropped a message that is not JSON")
            return
        }
        if let method = obj["method"] as? String {
            if method != "event" {
                let params = (try? JSONSerialization.data(withJSONObject: obj["params"] ?? [String: Any](), options: .fragmentsAllowed)) ?? Data("{}".utf8)
                notificationSink.yield(RPCNotification(method: method, params: params))
                return
            }
            guard let params = obj["params"],
                let pdata = try? JSONSerialization.data(withJSONObject: params),
                let ev = try? Self.decoder.decode(Event.self, from: pdata)
            else {
                noteDecodeFailure()
                return
            }
            eventSink.yield(ev)
            return
        }
        guard let id = (obj["id"] as? NSNumber)?.intValue else { return }
        if let err = obj["error"] as? [String: Any] {
            settle(
                id,
                .failure(
                    RPCError(
                        code: (err["code"] as? NSNumber)?.intValue ?? 0,
                        message: err["message"] as? String ?? "error",
                        data: Self.errorData(err["data"]))))
            return
        }
        let result = obj["result"] ?? NSNull()
        // Wrap so scalars and null survive JSONSerialization.
        let wrapped = (try? JSONSerialization.data(withJSONObject: ["r": result])) ?? Data("{\"r\":null}".utf8)
        settle(id, .success(wrapped))
    }

    /// `error.data` as a JSON value, or nil when absent or not representable.
    private static func errorData(_ raw: Any?) -> JSONValue? {
        guard let raw, let bytes = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed) else {
            return nil
        }
        return try? Self.decoder.decode(JSONValue.self, from: bytes)
    }

    private func noteDecodeFailure() {
        decodeFailures += 1
        Self.log.error("could not decode an event; skipped it")
        onDecodeFailure?()
    }

    /// Call `method` and decode its result.
    ///
    /// Throws `RPCError` with `RPCError.timedOut` if no answer arrives within `timeout`
    /// (the timer covers the send as well).
    public func call<R: Decodable>(
        _ method: String, _ params: some Encodable, as: R.Type = R.self, timeout: Duration = .seconds(30)
    ) async throws -> R {
        let json = String(decoding: try Self.encoder.encode(params), as: UTF8.self)
        let data = try await perform(method, paramsJSON: json, timeout: timeout)
        return try Self.decoder.decode(ResultBox<R>.self, from: data).r
    }

    /// Call a method with params that are already JSON (`jsonParams` is one JSON object). For params whose keys must
    /// reach the daemon as they are, where the snake_case encoder would rewrite them (the `values` of a form).
    public func call(_ method: String, jsonParams: Data, timeout: Duration = .seconds(30)) async throws {
        let text = String(decoding: jsonParams, as: UTF8.self)
        _ = try await perform(method, paramsJSON: text, timeout: timeout)
    }

    /// Like `call(_:jsonParams:)`, and returns the `result` as JSON bytes with its keys exactly as the daemon sent them.
    /// `call` decodes with the snake_case conversion, which would rewrite the keys of a shared payload (`system_prompt`,
    /// the names of its files). Decode the bytes with a plain `JSONDecoder` when the keys are data.
    public func callRawResult(_ method: String, jsonParams: Data, timeout: Duration = .seconds(30)) async throws -> Data {
        let text = String(decoding: jsonParams, as: UTF8.self)
        let data = try await perform(method, paramsJSON: text, timeout: timeout)
        guard let box = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let result = box["r"],
            let bytes = try? JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)
        else {
            throw RPCError(code: -32603, message: "the answer to \(method) does not match")
        }
        return bytes
    }

    /// Call a method whose result the caller doesn't need.
    public func call(_ method: String, _ params: some Encodable, timeout: Duration = .seconds(30)) async throws {
        _ = try await call(method, params, as: JSONValue.self, timeout: timeout)
    }

    private func perform(_ method: String, paramsJSON paramsString: String, timeout: Duration) async throws -> Data {
        if closed { throw endError ?? RPCError(code: RPCError.disconnected, message: "disconnected from the server") }
        let id = nextId
        nextId += 1
        let request = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\(jsonString(method)),\"params\":\(paramsString)}"

        slots[id] = .sent
        timers[id] = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            self.settle(id, .failure(RPCError(code: RPCError.timedOut, message: "the server did not answer in time")))
        }
        do {
            try await transport.send(request)
        } catch {
            timers.removeValue(forKey: id)?.cancel()
            slots[id] = nil
            throw error
        }
        // Suspend for the answer unless it (or the timeout) has already settled the slot.
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            switch slots[id] {
            case .settled(let result)?:
                slots[id] = nil
                c.resume(with: result)
            case .sent?:
                slots[id] = .waiting(c)
            case .waiting?, nil:
                // Unreachable: only this call moves a slot out of `.sent`. `nil` means
                // the client was failed while the request was being sent.
                c.resume(throwing: endError ?? RPCError(code: RPCError.disconnected, message: "disconnected from the server"))
            }
        }
    }

    /// Resolves one request exactly once: a waiting caller is resumed and its slot removed,
    /// so a late or duplicate answer (or a timer that lost the race) finds nothing to resume.
    private func settle(_ id: Int, _ result: Result<Data, Error>) {
        timers.removeValue(forKey: id)?.cancel()
        switch slots[id] {
        case .waiting(let c)?:
            slots[id] = nil
            c.resume(with: result)
        case .sent?:
            slots[id] = .settled(result)
        case .settled?, nil:
            break
        }
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
