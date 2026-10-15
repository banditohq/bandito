import Foundation

/// Sends this device's read marks of one server to its daemon (`messages.read`). At most one send per agent per
/// `interval`, and the newest mark wins: a read that comes during the wait is sent when the wait is over. A daemon
/// without the method (an older one) turns the sending off until the next connection (`resume`), without a word to the
/// person. A send that fails (offline, a lost connection) is dropped: the next read carries a newer mark.
@MainActor
public final class ReadMarkSync {
    /// One send: the RPC for an agent's mark. Nil while the server is not set up; nothing is scheduled then.
    public typealias Send = @MainActor (_ agentID: String, _ seq: Int64) async throws -> Void

    public var send: Send?
    /// The least time between two sends of one agent.
    public var interval: Duration

    /// The newest mark per agent that has not gone out yet.
    private var pending: [String: Int64] = [:]
    /// Agents with a send waiting for its turn (a task is scheduled for them).
    private var waiting: Set<String> = []
    /// When each agent's last send started.
    private var lastSent: [String: ContinuousClock.Instant] = [:]
    /// Set by a daemon that does not know the method, until `resume`.
    private var stopped = false

    public init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    /// Asks for `seq` to reach the daemon for `agentID`. It goes out at once when the agent's last send is at least
    /// `interval` ago, else when that interval is over; a later call before then replaces it.
    public func schedule(agentID: String, seq: Int64) {
        guard !stopped, send != nil else { return }
        pending[agentID] = seq
        guard !waiting.contains(agentID) else { return }
        let now = ContinuousClock.now
        let wait: Duration =
            lastSent[agentID].map { max(.zero, $0.advanced(by: interval) - now) } ?? .zero
        waiting.insert(agentID)
        Task { @MainActor [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            await self?.fire(agentID)
        }
    }

    /// Called on a new connection: a daemon that stopped the sending may have been upgraded.
    public func resume() {
        stopped = false
    }

    private func fire(_ agentID: String) async {
        waiting.remove(agentID)
        guard !stopped, let seq = pending.removeValue(forKey: agentID), let send else { return }
        lastSent[agentID] = ContinuousClock.now
        do {
            try await send(agentID, seq)
        } catch let error as RPCError where error.code == RPCError.methodNotFound {
            // An older daemon: no read marks until it is connected again. Nothing is shown.
            stopped = true
            pending.removeAll()
        } catch {
            // Offline or a failed call: this mark is lost, and the next read sends a newer one.
        }
    }
}
