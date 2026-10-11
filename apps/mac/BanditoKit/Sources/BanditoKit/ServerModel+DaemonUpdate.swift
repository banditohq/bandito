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

    /// The update the Server screens offer for this daemon (see `DaemonUpdateOffer.shown`).
    public var daemonUpdateOffer: DaemonUpdate? {
        DaemonUpdateOffer.shown(info: info, check: daemonUpdateCheck, checkedAt: daemonUpdateCheckedAt)
    }

    /// Asks the daemon to check for a newer release now (`daemon.update_check`) and keeps the answer in
    /// `daemonUpdateCheck` (nil when the call fails). Nothing is asked, and nothing is kept, when the server is not
    /// connected or the daemon has no `update` feature (an older daemon).
    @discardableResult
    public func checkDaemonUpdate() async -> DaemonUpdateCheck? {
        guard state == .connected, supports("update"), let c = try? rpc() else { return nil }
        let answer = try? await c.call("daemon.update_check", NoParams(), as: DaemonUpdateCheck.self)
        daemonUpdateCheck = answer
        daemonUpdateCheckedAt = Date()
        return answer
    }

    /// Asks the daemon for its check when it is needed: this server is not this Mac (its daemon is replaced from the
    /// app bundle), the daemon has the `update` feature, and `daemon.info` carries no offer. Run on connect, every hour
    /// and when the Server screen opens.
    public func refreshDaemonUpdateCheck() async {
        guard !LocalDaemonUpgrade.isThisMac(config), supports("update"), DaemonUpdateOffer.offer(for: info) == nil
        else { return }
        await checkDaemonUpdate()
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
