import BanditoKit
import Foundation

/// The demo world of the `-demo` launch argument: BanditoKit's demo daemons, with a small team on the first and an empty
/// second server, so the core can be checked on the simulator without a server. `-demo-empty` shows the first server
/// without any agent. Nothing leaves the process.
@MainActor
enum IOSDemo {
    static let launchArgument = "-demo"
    static let emptyArgument = "-demo-empty"
    static let serverID = UUID(uuidString: "6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B")!
    static let officeServerID = UUID(uuidString: "2A7D9E40-5B1C-4F8E-8C33-7E0A1B2C3D4E")!

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
        arguments.contains(launchArgument) || arguments.contains(emptyArgument)
    }

    /// Whether the launch arguments ask for the demo world with no agent on its first server.
    static func isEmptyRequested(in arguments: [String]) -> Bool {
        arguments.contains(emptyArgument)
    }

    /// The demo servers, connected: the team's (or none) and an office server with no agent, so the server switcher
    /// has something to switch to.
    static func startServers(withTeam: Bool = true) async -> [ServerModel] {
        let main = await start(withTeam: withTeam)
        let office = await startOffice()
        return [main, office]
    }

    /// Makes the demo server, connects it, and installs the team. The team goes in after the connect: the connect
    /// reads the agents of the daemon, which has none of its own. Forge asks for an approval, so the Crew shows a card.
    static func start(withTeam: Bool = true) async -> ServerModel {
        let members = withTeam ? team : []
        let ids = members.indices.map { "ios-demo-\($0 + 1)" }
        let (server, _) = DemoDaemon.server(
            id: serverID, name: "Demo", setup: DemoDaemonSetup(agentIDs: ids, hostname: "demo"))
        await server.connect()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (index, member) in members.enumerated() {
            let agent = Agent(
                id: ids[index], name: member.name, role: member.role, runtime: member.runtime,
                cwd: DemoDaemonFiles.projects, createdAt: now, updatedAt: now, status: member.status)
            server.installSyntheticAgent(agent, items: [])
        }
        if let forge = ids.first {
            server.apply(
                Event(
                    seq: server.thread(for: forge).lastSeq + 1, agentId: forge, ts: now,
                    body: .approvalRequested(
                        approvalId: "ios-demo-approval-1", callId: "ios-demo-call-1", tool: "bash",
                        title: "git push origin feat/ios-crew", command: "git push origin feat/ios-crew", diff: nil,
                        reason: "Publishes the branch")))
        }
        return server
    }

    /// A second demo server with no agent, connected.
    static func startOffice() async -> ServerModel {
        let (server, _) = DemoDaemon.server(
            id: officeServerID, name: "Office", setup: DemoDaemonSetup(agentIDs: [], hostname: "office"))
        await server.connect()
        return server
    }
}
