import CryptoKit
import Foundation

// A phone's (or any app's) connection to a daemon through Bandito Relay (docs/RELAY.md): a WebSocket to the relay, an
// end-to-end Noise session with the daemon inside it (the relay only forwards bytes), then the same JSON-RPC text frames
// as `/v1/rpc`. The daemon is known by the Noise key `nk` of the pairing link, never by the relay.

/// The reasons a relay connection ends in words the app can show (`FailureKind.reason`).
public enum RelayFailure {
    /// The server is not connected to the relay (HTTP 503 before the upgrade, or the registration was deleted).
    public static let offline = "relay_offline"
    /// The monthly traffic limit (close 4008).
    public static let limit = "relay_limit"
    /// Too many connections or messages (HTTP 429, close 4010): wait a little.
    public static let busy = "relay_busy"
    /// The peer is not the daemon whose key the link carries.
    public static let keyMismatch = "relay_key_mismatch"

    static func error(_ reason: String, _ text: String, code: Int = RPCError.relay) -> RPCError {
        RPCError(code: code, message: "\(reason): \(text)")
    }

    /// What a WebSocket close code of the relay means. The codes that mean "try again" (replaced 4001, silence 4002,
    /// server left 4004, oversize 4009, no first frame 4011) are a plain lost link: the app reconnects without a word.
    static func error(forClose code: Int) -> RPCError {
        switch code {
        case 4003:
            return error(offline, "the server is no longer registered with the relay")
        case 4008:
            return error(limit, "the monthly traffic limit of the relay is reached")
        case 4010:
            return error(busy, "too many messages", code: RPCError.rateLimited)
        default:
            return RPCError(code: RPCError.disconnected, message: "the relay closed the connection (\(code))")
        }
    }

    /// What an HTTP answer of the relay before the upgrade means.
    static func error(forStatus status: Int?) -> RPCError? {
        switch status {
        case 503: return error(offline, "the server is not connected to the relay")
        case 429: return error(busy, "too many connections, try again in a minute", code: RPCError.rateLimited)
        default: return nil
        }
    }

    /// What the daemon says inside the session before it closes it.
    static func error(forDaemon reason: String) -> RPCError {
        switch reason {
        case "unauthorized":
            return RPCError(code: RPCError.keyRejected, message: "the server rejected the device key")
        case "rate_limited":
            return RPCError(code: RPCError.rateLimited, message: "too many attempts, try again in a few minutes")
        default:
            return RPCError(code: RPCError.disconnected, message: "the server refused the connection (\(reason))")
        }
    }
}

public actor RelayTransport: RPCTransport, RouteReporting {
    /// What the phone is for in this stream: a paired device with its token, or a first pairing (`pair.redeem` only).
    public enum Role: Sendable, Equatable {
        case device(token: String)
        case pairing
    }

    public static let defaultTimeout: Duration = .seconds(12)
    public static let keepaliveInterval: Duration = .seconds(25)

    private let route: RelayRoute
    private let daemonKey: Data
    private let phoneKey: Curve25519.KeyAgreement.PrivateKey
    private let role: Role
    private let timeout: Duration
    private let keepalive: Duration
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var noise: NoiseTransport?
    private var joiner = NoiseFraming.Joiner()
    private var keepaliveTask: Task<Void, Never>?
    private var didTimeOut = false
    /// Whether the Noise handshake is still under way: a stream closed in it is a peer that is not the daemon we pin.
    private var inHandshake = true

    public init(
        route: RelayRoute, daemonKey: Data, phoneKey: Curve25519.KeyAgreement.PrivateKey, role: Role,
        timeout: Duration = RelayTransport.defaultTimeout, keepalive: Duration = RelayTransport.keepaliveInterval
    ) {
        self.route = route
        self.daemonKey = daemonKey
        self.phoneKey = phoneKey
        self.role = role
        self.timeout = timeout
        self.keepalive = keepalive
    }

    public var connectedRoute: ConnectionRoute? { noise == nil ? nil : .cloud }

    public func connect() async throws {
        guard let url = route.clientURL else {
            throw RPCError(code: RPCError.disconnected, message: "the relay address is not usable")
        }
        var initiator = try NoiseInitiator(staticKey: phoneKey, remoteStatic: daemonKey)
        let urlSession = URLSession(configuration: .ephemeral)
        session = urlSession
        let socket = urlSession.webSocketTask(with: url)
        socket.maximumMessageSize = 1 << 20
        task = socket
        socket.resume()
        do {
            // The relay closes a stream that sends no binary frame within 15 s: message 1 goes out at once.
            let first = try initiator.writeMessage1(payload: Data(#"{"v":1}"#.utf8))
            // Reading starts before writing: a relay that closes at once (a limit) is heard even if the write fails.
            let reader = Task { try await self.nextBinary() }
            var writeError: Error?
            do { try await post([first]) } catch { writeError = error }
            let reply: Data
            do {
                reply = try await withTimeout { try await reader.value }
            } catch {
                reader.cancel()
                throw error
            }
            if let writeError { throw writeError }
            let (payload, transport) = try initiator.readMessage2(reply)
            guard (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["v"] as? Int == 1 else {
                throw NoiseError.handshakeFailed
            }
            noise = transport
            inHandshake = false
            try await sendMessage(Self.firstMessage(for: role))
            keepaliveTask = Task { [weak self, keepalive] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: keepalive)
                    if Task.isCancelled { return }
                    await self?.ping()
                }
            }
        } catch {
            let failure = await mapped(error)
            await close()
            throw failure
        }
    }

    static func firstMessage(for role: Role) -> String {
        switch role {
        case .pairing: return #"{"pair":true}"#
        case .device(let token):
            let data = (try? JSONSerialization.data(withJSONObject: ["auth": token])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    public func send(_ text: String) async throws {
        guard task != nil, noise != nil else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        do {
            try await sendMessage(text)
        } catch {
            throw await mapped(error)
        }
    }

    public func receive() async throws -> String {
        guard let socket = task else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        do {
            while true {
                switch try await socket.receive() {
                case .string(let text):
                    if text == "ping" { try await postText("pong") }
                case .data(let cipher):
                    guard var transport = noise else { throw NoiseError.decryptFailed }
                    let plain = try transport.decrypt(cipher)
                    noise = transport
                    guard let frame = try joiner.push(plain) else { continue }
                    let text = String(decoding: frame, as: UTF8.self)
                    if let refusal = Self.daemonRefusal(in: text) { throw RelayFailure.error(forDaemon: refusal) }
                    return text
                @unknown default:
                    continue
                }
            }
        } catch {
            throw await mapped(error)
        }
    }

    public func close() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        noise = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: internals

    /// `{"error": "unauthorized"}` and nothing else: the daemon's refusal, sent encrypted before it closes the stream.
    static func daemonRefusal(in text: String) -> String? {
        guard text.utf8.count < 200, text.hasPrefix("{"),
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            object.count == 1, let reason = object["error"] as? String
        else { return nil }
        return reason
    }

    private func ping() async {
        try? await postText("ping")
    }

    /// Encrypts a frame as one or more Noise messages and queues them all, in order, before anything else can send:
    /// two frames never interleave their chunks.
    private func sendMessage(_ text: String) async throws {
        guard var transport = noise else { throw NoiseError.decryptFailed }
        var cipher: [Data] = []
        for part in NoiseFraming.split(Data(text.utf8)) { cipher.append(try transport.encrypt(part)) }
        noise = transport
        try await post(cipher)
    }

    private func postText(_ text: String) async throws {
        guard let socket = task else { return }
        try await socket.send(.string(text))
    }

    /// Queues binary messages in order (no suspension between them) and waits until the last is out.
    private func post(_ messages: [Data]) async throws {
        guard let socket = task, let last = messages.last else { return }
        for message in messages.dropLast() { socket.send(.data(message)) { _ in } }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            socket.send(.data(last)) { error in
                if let error { k.resume(throwing: error) } else { k.resume() }
            }
        }
    }

    /// The next binary message; the relay's `ping` is answered on the way.
    private func nextBinary() async throws -> Data {
        guard let socket = task else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        while true {
            switch try await socket.receive() {
            case .data(let data): return data
            case .string(let text): if text == "ping" { try await postText("pong") }
            @unknown default: continue
            }
        }
    }

    private func withTimeout<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let limit = timeout
        let socket = task
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                await self.markTimedOut()
                socket?.cancel(with: .goingAway, reason: nil)
                throw RPCError(code: RPCError.timedOut, message: "no answer within the time limit")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    private func markTimedOut() { didTimeOut = true }

    /// Turns what the socket or the session threw into an `RPCError` the app can word.
    private func mapped(_ error: Error) async -> Error {
        if didTimeOut { return RPCError(code: RPCError.timedOut, message: "no answer within the time limit") }
        if let rpc = error as? RPCError { return rpc }
        if error is CancellationError { return error }
        if let noise = error as? NoiseError {
            switch noise {
            case .handshakeFailed, .badKey:
                return RelayFailure.error(RelayFailure.keyMismatch, "the peer is not the server whose key this device trusts")
            default:
                return RPCError(code: RPCError.disconnected, message: "the encrypted session broke")
            }
        }
        guard let socket = task else { return error }
        if let failure = RelayFailure.error(forStatus: (socket.response as? HTTPURLResponse)?.statusCode) { return failure }
        // The close frame is only read while someone reads: after a failed write, read once so its code is known.
        if socket.closeCode == .invalid, socket.response != nil {
            let reader = Task { _ = try? await socket.receive() }
            let waiter = Task {
                try? await Task.sleep(for: .milliseconds(300))
                reader.cancel()
            }
            for _ in 0..<15 where socket.closeCode == .invalid {
                try? await Task.sleep(for: .milliseconds(20))
            }
            waiter.cancel()
            if socket.closeCode == .invalid { socket.cancel(with: .goingAway, reason: nil) }
        }
        let code = socket.closeCode.rawValue
        if code >= 4000 { return RelayFailure.error(forClose: code) }
        // Closed during the handshake without a word: the daemon drops a stream whose first message it cannot open.
        if inHandshake, (socket.response as? HTTPURLResponse)?.statusCode == 101 {
            return RelayFailure.error(RelayFailure.keyMismatch, "the stream was closed during the handshake")
        }
        return error
    }
}
