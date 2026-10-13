import BanditoKit
import BanditoL10n
import Foundation

/// What the Servers list of Settings shows about one server, from its live model.
struct ServerRowFacts: Equatable {
    enum Via: Equatable {
        case tailscale, lan, cloud
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
        if let direct = server.config.endpoint.directPart {
            hosts = direct.hosts
            let used = memory.lastGood(for: direct.fingerprint).flatMap { direct.hosts.contains($0) ? $0 : nil } ?? direct.hosts.first
            if let used, DirectHost.parse(used)?.isTailscale == true { via = .tailscale }
        }
        // What the open connection really uses wins; a server that is only on the cloud says so before it connects too.
        if server.connectionRoute == .cloud || (server.connectionRoute == nil && server.config.endpoint.directPart == nil && server.config.endpoint.relayPart != nil) {
            via = .cloud
        }
        return ServerRowFacts(name: server.config.name, isOnline: server.state == .connected, via: via, addresses: hosts)
    }

    var viaTitle: String {
        switch via {
        case .tailscale: L10n.Ios.Settings.Servers.Via.tailscale
        case .lan: L10n.Ios.Settings.Servers.Via.lan
        case .cloud: L10n.Ios.Settings.Servers.Via.cloud
        }
    }
}
