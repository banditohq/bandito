import BanditoKit
import Foundation

/// What the Updates card of a remote server shows about its daemon's update: the install button, the result of the
/// daemon's own check, or only the GitHub line. Pure, so the card and its tests agree
/// (docs/ARCHITECTURE.md#self-update). The offer itself comes from `ServerModel.daemonUpdateOffer`, the one rule every
/// Server screen uses.
enum RemoteDaemonUpdateRules {
    enum Choice: Equatable {
        /// A newer release to install with the button.
        case offer(DaemonUpdate)
        /// The daemon's check says the server runs the newest release.
        case upToDate
        /// The check is asked and has not answered yet.
        case checking
        /// Only the GitHub line and the manual command.
        case releaseOnly
    }

    /// `info` nil: the server has not reported yet, and the card says so before this is asked. `offer` is
    /// `ServerModel.daemonUpdateOffer`. `connected` false or a daemon without the `update` feature (or in safe mode):
    /// no check is asked, so only the GitHub line is shown. `checkAsked`: the server's check was asked
    /// (`ServerModel.daemonUpdateCheckedAt` is set).
    static func choice(
        info: DaemonInfo?, connected: Bool, offer: DaemonUpdate?, check: DaemonUpdateCheck?, checkAsked: Bool
    ) -> Choice {
        guard let info else { return .releaseOnly }
        if let offer { return .offer(offer) }
        guard connected, info.supports("update"), !info.isSafeMode else { return .releaseOnly }
        guard checkAsked else { return .checking }
        // A failed check is the same as no check: the GitHub line.
        guard let check else { return .releaseOnly }
        guard check.available else { return .upToDate }
        // An available release that is not newer than the daemon (no offer) means the daemon is already on it.
        guard let text = check.latest, SemanticVersion(text) != nil else { return .releaseOnly }
        return .upToDate
    }
}
