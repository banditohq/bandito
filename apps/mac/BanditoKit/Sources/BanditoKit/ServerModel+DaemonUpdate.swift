import Foundation

// The daemon's own update: the update check it reports and asking it to install a release
// (docs/ARCHITECTURE.md#self-update).

extension ServerModel {
    /// Re-reads `daemon.info`, so the update offer follows the daemon's own check. Does nothing unless connected.
    /// A failed read keeps the last answer.
    public func refreshInfo() async {
        guard state == .connected, let c = try? rpc() else { return }
        if let fresh = try? await c.call("daemon.info", NoParams(), as: DaemonInfo.self) {
            info = fresh
        }
    }

    /// Asks the daemon to install `version` (`daemon.update_apply`, without `v`). The reply comes before the restart,
    /// so the link drops right after: the caller then waits for `info.version` to change. Returns whether a service
    /// manager restarts the daemon (false: the new binary waits for a manual restart).
    /// Downloading and checking the release can take a while, so the call waits up to five minutes.
    public func updateDaemon(to version: String) async throws -> Bool {
        struct P: Encodable { var version: String }
        let reply = try await rpc().call(
            "daemon.update_apply", P(version: version), as: DaemonUpdateResult.self, timeout: .seconds(300))
        return reply.restarting
    }
}
