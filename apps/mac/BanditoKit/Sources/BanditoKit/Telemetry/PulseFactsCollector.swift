import Foundation

/// Builds the pulse from what the servers already know: `daemon.info` (system, architecture, daemon version) and the
/// agents each server listed. Telegram is asked only of connected servers; a question that fails counts as "not
/// linked". No address, name or host is read into the result.
@MainActor
public enum PulseFactsCollector {
    public static func facts(
        servers: [ServerModel], client: ClientInfo, lang: String, region: String?
    ) async -> PulseFacts {
        var pulseServers: [PulseServer] = []
        var agentCount = 0
        var runtimes = Set<String>()
        var telegram = false
        for server in servers {
            if let info = server.info {
                pulseServers.append(PulseServer(os: info.os, arch: info.arch, daemon: info.version))
            }
            agentCount += server.agents.count
            for agent in server.agents {
                runtimes.insert(agent.runtime.rawValue)
            }
            if server.state == .connected, let status = try? await server.telegramStatus() {
                telegram = telegram || (status.configured && !status.chats.isEmpty)
            }
        }
        return PulseFacts(
            client: client, lang: lang, region: region, servers: pulseServers, agentCount: agentCount,
            runtimes: Array(runtimes), telegram: telegram)
    }
}
