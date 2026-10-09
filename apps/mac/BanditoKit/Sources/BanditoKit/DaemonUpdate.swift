import Foundation

/// The daemon's own check for a newer release, as `daemon.info` carries it (`update`, null until a check succeeded).
public struct DaemonUpdate: Codable, Sendable, Hashable {
    /// The daemon's version, `X.Y.Z`.
    public var current: String
    /// The newest release the check found, `X.Y.Z` without `v`.
    public var latest: String
    public var available: Bool
    /// When the check ran, Unix milliseconds.
    public var checkedAt: Int64
}

/// The answer of `daemon.update_apply`: the release is installed. `restarting` is false when no service manager
/// restarts the daemon, so the new binary waits for a manual restart.
public struct DaemonUpdateResult: Codable, Sendable, Hashable {
    public var ok: Bool
    public var restarting: Bool
}

/// Rules for offering the daemon's update in the Server screens. Pure, so the app and its tests agree.
public enum DaemonUpdateOffer {
    /// The update to offer for this daemon, or nil. Nothing is offered when the daemon has no check result yet, reports no
    /// newer release, or reports a `latest` that is not newer than its own version.
    public static func offer(for info: DaemonInfo?) -> DaemonUpdate? {
        guard let update = info?.update, update.available,
            let latest = SemanticVersion(update.latest),
            ReleaseFeed.isUpdateAvailable(current: update.current, latest: latest)
        else { return nil }
        return update
    }

    /// True once the daemon reports `target` as its version. After a restart the reconnect sets `info` again.
    public static func isApplied(_ info: DaemonInfo?, target: String) -> Bool {
        info?.version == target
    }
}
