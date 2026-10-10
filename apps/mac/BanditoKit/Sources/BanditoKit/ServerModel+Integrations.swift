import Foundation

// MCP integrations for the agents (docs/ARCHITECTURE.md#integrations). Owner and app methods only.

extension ServerModel {
    /// Every integration the owner added, in the daemon's order.
    public func integrations() async throws -> [Integration] {
        try await rpc().call("integrations.list", NoParams(), as: [Integration].self)
    }

    /// The templates built into the daemon, for the "Каталог" grid.
    public func integrationCatalog() async throws -> [IntegrationCatalogEntry] {
        try await rpc().call("integrations.catalog", NoParams(), as: [IntegrationCatalogEntry].self)
    }

    /// Adds an integration. The daemon refuses a name that is taken or a definition it cannot run.
    @discardableResult
    public func addIntegration(_ new: NewIntegration) async throws -> Integration {
        try await rpc().call("integrations.add", new, as: Integration.self)
    }

    @discardableResult
    public func updateIntegration(_ id: String, patch: IntegrationPatch) async throws -> Integration {
        try await rpc().call("integrations.update", IntegrationUpdateParams(id: id, patch: patch), as: Integration.self)
    }

    /// Returns true when the integration existed.
    @discardableResult
    public func removeIntegration(_ id: String) async throws -> Bool {
        struct P: Encodable { var id: String }
        struct Reply: Decodable { var deleted: Bool }
        return try await rpc().call("integrations.remove", P(id: id), as: Reply.self).deleted
    }

    /// Starts the server once and lists its tools. A failure is an answer (`ok: false` with the text), not a thrown error.
    public func testIntegration(_ id: String) async throws -> IntegrationTest {
        struct P: Encodable { var id: String }
        return try await rpc().call("integrations.test", P(id: id), as: IntegrationTest.self, timeout: .seconds(30))
    }

    /// Starts a draft integration the way `testIntegration` starts a saved one, and saves nothing. Needs the
    /// `integrations_probe` feature. The draft's values stay in the daemon's memory.
    public func probeIntegration(_ draft: NewIntegration) async throws -> IntegrationTest {
        struct P: Encodable { var draft: NewIntegration }
        return try await rpc().call("integrations.probe", P(draft: draft), as: IntegrationTest.self, timeout: .seconds(30))
    }
}

/// `integrations.update` params: the id and the patch fields in one object.
struct IntegrationUpdateParams: Encodable, Sendable {
    var id: String
    var patch: IntegrationPatch

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: IntegrationPatch.Key.self)
        try c.encode(id, forKey: .id)
        try patch.encodeFields(into: &c)
    }
}
