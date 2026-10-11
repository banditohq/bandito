import BanditoKit
import Foundation
import Network

/// What `OAuthSignIn` needs of a loopback listener (a fake in tests).
public protocol OAuthLoopbackListening: AnyObject, Sendable {
    /// Returns when the socket is listening; throws `OAuthLoopbackError` when it cannot.
    func start() async throws
    /// Closes the socket and every connection. Safe to call twice.
    func stop()
}

public enum OAuthLoopbackError: Error, Equatable {
    /// Another program holds the port.
    case portBusy
    case failed
}

/// Listens on `127.0.0.1:45819` (IPv4 loopback only, never every address) for the one request a sign-in brings back
/// (RFC 8252 section 7.3). The pure part, what a request means and what to answer, is `OAuthLoopback`.
///
/// - One connection is read at a time; the rest wait their turn (a browser may open a spare socket first). A connection
///   that says nothing for 5 seconds is dropped.
/// - A request for another path, or with another state, is answered and the listener goes on waiting.
/// - The right callback is answered with a page, then the listener closes and `onCallback` is called once.
public final class OAuthLoopbackListener: OAuthLoopbackListening, @unchecked Sendable {
    private let state: String
    private let port: UInt16
    private let onCallback: @Sendable (OAuthCallback) -> Void
    private let queue = DispatchQueue(label: "dev.bandito.oauth-loopback")
    // Everything below is touched on `queue` only.
    private var listener: NWListener?
    private var active: NWConnection?
    private var waiting: [NWConnection] = []
    private var finished = false
    private var startReply: CheckedContinuation<Void, Error>?

    static let idleSeconds = 5.0
    static let maxWaiting = 8

    /// `port` is 45819 in the app; tests pass 0 and read `boundPort`.
    public init(state: String, port: UInt16 = OAuthLoopback.port, onCallback: @escaping @Sendable (OAuthCallback) -> Void) {
        self.state = state
        self.port = port
        self.onCallback = onCallback
    }

    /// The port the socket has, once `start` returned.
    public var boundPort: UInt16? { queue.sync { listener?.port?.rawValue } }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            queue.async { self.open(reply) }
        }
    }

    private func open(_ reply: CheckedContinuation<Void, Error>) {
        guard listener == nil, !finished else {
            reply.resume(throwing: OAuthLoopbackError.failed)
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        let local = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: local)
        guard let made = try? NWListener(using: parameters) else {
            reply.resume(throwing: OAuthLoopbackError.failed)
            return
        }
        listener = made
        startReply = reply
        made.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async { self.listenerChanged(state) }
        }
        made.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async { self.accept(connection) }
        }
        made.start(queue: queue)
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            startReply?.resume()
            startReply = nil
        case .failed(let error), .waiting(let error):
            let busy = Self.isAddressInUse(error)
            if let reply = startReply {
                startReply = nil
                reply.resume(throwing: busy ? OAuthLoopbackError.portBusy : OAuthLoopbackError.failed)
            }
            closeAll()
        default:
            break
        }
    }

    private static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
    }

    public func stop() {
        queue.async { self.closeAll() }
    }

    private func closeAll() {
        finished = true
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        active?.cancel()
        for connection in waiting { connection.cancel() }
        active = nil
        waiting = []
        if let reply = startReply {
            startReply = nil
            reply.resume(throwing: OAuthLoopbackError.failed)
        }
    }

    // MARK: - connections

    private func accept(_ connection: NWConnection) {
        guard !finished else {
            connection.cancel()
            return
        }
        if active == nil {
            serve(connection)
        } else if waiting.count < Self.maxWaiting {
            waiting.append(connection)
        } else {
            connection.cancel()
        }
    }

    private func serve(_ connection: NWConnection) {
        active = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { self.queue.async { self.done(connection) } }
            if case .cancelled = state { self.queue.async { self.done(connection) } }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.idleSeconds) { [weak self, weak connection] in
            // Still the same connection after the wait: it said nothing worth answering.
            guard let self, let connection, self.active === connection else { return }
            connection.cancel()
        }
        read(connection, so_far: Data())
    }

    private func read(_ connection: NWConnection, so_far: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: OAuthLoopback.maxRequestBytes + 1) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard self.active === connection, !self.finished else { return }
                let all = so_far + (data ?? Data())
                if error != nil || (isComplete && (data ?? Data()).isEmpty) {
                    connection.cancel()
                    return
                }
                let verdict = OAuthLoopback.evaluate(all, expectedState: self.state)
                if verdict == .incomplete {
                    self.read(connection, so_far: all)
                } else {
                    self.answer(connection, verdict, all)
                }
            }
        }
    }

    private func answer(_ connection: NWConnection, _ verdict: OAuthLoopback.Verdict, _ request: Data) {
        let reply = OAuthLoopback.response(for: verdict, acceptLanguage: OAuthLoopback.acceptLanguage(in: request))
        var callback: OAuthCallback?
        if case .callback(let found) = verdict { callback = found }
        connection.send(
            content: reply, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    connection.cancel()
                    guard let callback, !self.finished else { return }
                    // The right answer: nothing else is waited for.
                    self.closeAll()
                    self.onCallback(callback)
                }
            })
    }

    private func done(_ connection: NWConnection) {
        if let index = waiting.firstIndex(where: { $0 === connection }) {
            waiting.remove(at: index)
            return
        }
        guard active === connection else { return }
        active = nil
        if !finished, !waiting.isEmpty { serve(waiting.removeFirst()) }
    }
}
