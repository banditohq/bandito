import Foundation

// Slash commands on the server (feature `commands`). See docs/ARCHITECTURE.md#commands.

extension ServerModel {
    /// The commands and skills the agent can run, from the daemon.
    public func commands(agentID: String) async throws -> [AgentCommand] {
        struct P: Encodable { var agentId: String }
        return try await rpc().call("commands.list", P(agentId: agentID), as: [AgentCommand].self)
    }

    /// Copies a command or skill into the server user's home. Returns the path it was written to.
    @discardableResult
    public func installCommand(_ request: CommandInstallRequest) async throws -> String {
        struct Reply: Decodable { var path: String }
        return try await rpc().call("commands.install", request, as: Reply.self).path
    }
}
