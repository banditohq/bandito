import Foundation

/// The one update the sidebar's banner shows: the app's own, or a server's daemon update.
enum UpdateBannerChoice: Equatable {
    case none
    case app
    case server(id: UUID, version: String)
}

/// A server as the banner rule reads it: its name, and the daemon version it offers now (nil when it offers none).
struct ServerUpdateCandidate: Equatable {
    var id: UUID
    var name: String
    var version: String?
    /// True for a live offer of a connected server. False for the outcome of an update this app ran (kept after it).
    var isLive: Bool
}

/// Which update the sidebar shows, and which server the server menu offers. Pure, so the choice is tested alone.
enum UpdateBannerRule {
    /// The app's update wins: while one is on screen, no server update is shown (one banner at a time). Otherwise the
    /// server update of `serverOffer`.
    static func choose(
        appVisible: Bool, servers: [ServerUpdateCandidate], selected: UUID?,
        isDismissed: (UUID, String) -> Bool
    ) -> UpdateBannerChoice {
        if appVisible { return .app }
        guard let pick = serverOffer(servers: servers, selected: selected, isDismissed: isDismissed),
            let version = pick.version
        else { return .none }
        return .server(id: pick.id, version: version)
    }

    /// The server whose update is offered: the selected server first when it has one, else the first server in order.
    /// Only servers with an offer count, and a dismissed offer does not (`isDismissed` is asked per server and version).
    /// The menu asks for live offers only: an outcome is not a release to install again.
    static func serverOffer(
        servers: [ServerUpdateCandidate], selected: UUID?, isDismissed: (UUID, String) -> Bool = { _, _ in false },
        liveOnly: Bool = false
    ) -> ServerUpdateCandidate? {
        let offering = servers.filter { candidate in
            guard let version = candidate.version else { return false }
            if liveOnly, !candidate.isLive { return false }
            return !isDismissed(candidate.id, version)
        }
        return offering.first { $0.id == selected } ?? offering.first
    }
}

/// The × of the server banner: a server keeps the one version it was dismissed for, so a newer release shows again.
/// A value the banner holds in its state (a dismiss must redraw it), saved in the app's defaults.
struct ServerUpdateDismissals: Equatable {
    static let storageKey = "updateBanner.dismissedServerUpdates"

    /// The dismissed version of each server, by the server's id.
    private(set) var versions: [String: String]

    init(versions: [String: String] = [:]) {
        self.versions = versions
    }

    static func load(defaults: UserDefaults = .standard) -> ServerUpdateDismissals {
        ServerUpdateDismissals(versions: (defaults.dictionary(forKey: storageKey) as? [String: String]) ?? [:])
    }

    func isDismissed(server: UUID, version: String) -> Bool {
        versions[server.uuidString] == version
    }

    /// Keeps `version` as the dismissed one of `server` (replacing an earlier one) and saves the value.
    mutating func dismiss(server: UUID, version: String, defaults: UserDefaults = .standard) {
        versions[server.uuidString] = version
        defaults.set(versions, forKey: Self.storageKey)
    }
}
