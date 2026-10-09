import Foundation

// API keys and passwords that agents get as environment variables (docs/ARCHITECTURE.md#secrets).
// Values are write-only: no method returns one.

extension ServerModel {
    /// All secrets, sorted by name. Only the last 4 characters of each value are included.
    public func secrets() async throws -> [SecretInfo] {
        try await rpc().call("secrets.list", NoParams(), as: [SecretInfo].self)
    }

    /// Creates a secret or replaces its value and agents. `agents`: agent ids, `["*"]` for every agent.
    @discardableResult
    public func setSecret(name: String, value: String, agents: [String]) async throws -> SecretInfo {
        struct P: Encodable { var name: String; var value: String; var agents: [String] }
        return try await rpc().call(
            "secrets.set", P(name: name, value: value, agents: agents), as: SecretInfo.self)
    }

    /// Returns true when a secret with this name existed.
    @discardableResult
    public func deleteSecret(name: String) async throws -> Bool {
        struct P: Encodable { var name: String }
        struct Reply: Decodable { var deleted: Bool }
        return try await rpc().call("secrets.delete", P(name: name), as: Reply.self).deleted
    }
}
