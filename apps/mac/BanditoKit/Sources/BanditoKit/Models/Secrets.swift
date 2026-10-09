import Foundation

// Wire model for `secrets.*` (docs/ARCHITECTURE.md#secrets). No method returns a value.

public struct SecretInfo: Codable, Sendable, Identifiable, Hashable {
    public var name: String
    /// Last 4 characters of a value of 12 or more characters; otherwise empty.
    public var tail: String
    /// Agent ids that get the secret; `["*"]` for every agent, `[]` for none yet.
    public var agents: [String]
    /// Unix milliseconds.
    public var updatedAt: Int64

    public var id: String { name }
}
