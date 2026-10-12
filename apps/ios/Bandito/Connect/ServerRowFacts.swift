import BanditoKit
import BanditoL10n
import Foundation

/// What the Servers list of Settings shows about one server, from its live model.
struct ServerRowFacts: Equatable {
    enum Via: Equatable {
        case tailscale, lan
    }

    var name: String
    var isOnline: Bool
    var via: Via
    /// The addresses of a direct server, as `host:port`, best first; empty for a demo or any other kind.
    var addresses: [String]

    /// The address the app reached last counts for "via": a server paired on the home Wi-Fi and reached over Tailscale
    /// from the road says Tailscale when it is. Without a remembered address, the first one decides.
    @MainActor
    static func make(_ server: ServerModel, memory: DirectHostMemory = .shared) -> ServerRowFacts {
        var hosts: [String] = []
        var via = Via.lan
        if case .direct(let all, let fingerprint) = server.config.endpoint {
            hosts = all
            let used = memory.lastGood(for: fingerprint).flatMap { all.contains($0) ? $0 : nil } ?? all.first
            if let used, DirectHost.parse(used)?.isTailscale == true { via = .tailscale }
        }
        return ServerRowFacts(name: server.config.name, isOnline: server.state == .connected, via: via, addresses: hosts)
    }

    var viaTitle: String {
        switch via {
        case .tailscale: L10n.Ios.Settings.Servers.Via.tailscale
        case .lan: L10n.Ios.Settings.Servers.Via.lan
        }
    }
}
