import BanditoKit
import Foundation

/// The demo world of the `-demo` launch argument: BanditoKit's demo daemon with a small team installed on it, so the
/// core can be checked on the simulator without a server. Nothing leaves the process.
@MainActor
enum IOSDemo {
    static let launchArgument = "-demo"
    static let serverID = UUID(uuidString: "6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B")!

    struct Member: Sendable {
        let name: String
        let role: String
        let runtime: RuntimeKind
        let status: AgentStatus
    }

    static let team: [Member] = [
        Member(name: "Forge", role: "Builder", runtime: .claude, status: .working),
        Member(name: "Scout", role: "Researcher", runtime: .codex, status: .idle),
        Member(name: "Watch", role: "On call", runtime: .grok, status: .needsYou),
        Member(name: "Quill", role: "Docs", runtime: .claude, status: .error),
    ]

    /// Whether the launch arguments ask for the demo world.
    static func isRequested(in arguments: [String]) -> Bool {
        arguments.contains(launchArgument)
    }

    /// Makes the demo server, connects it, and installs the team. The team goes in after the connect: the connect
    /// reads the agents of the daemon, which has none of its own.
    static func start() async -> ServerModel {
        let ids = team.indices.map { "ios-demo-\($0 + 1)" }
        let (server, _) = DemoDaemon.server(
            id: serverID, name: "Demo", setup: DemoDaemonSetup(agentIDs: ids, hostname: "demo"))
        await server.connect()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (index, member) in team.enumerated() {
            let agent = Agent(
                id: ids[index], name: member.name, role: member.role, runtime: member.runtime,
                cwd: DemoDaemonFiles.projects, createdAt: now, updatedAt: now, status: member.status)
            server.installSyntheticAgent(agent, items: [])
        }
        return server
    }
}
