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

    /// Brings an integration up to its catalog template: command, arguments and address only; secrets, headers and
    /// the agents' lists stay. Refused when the row has no `template_update`. Needs the `template_updates` feature.
    @discardableResult
    public func updateIntegrationFromTemplate(_ id: String) async throws -> Integration {
        struct P: Encodable { var id: String }
        return try await rpc().call("integrations.update_from_template", P(id: id), as: Integration.self)
    }

    /// The catalog services that suit an agent's project folder, with the reason (`integrations.recommend`, feature
    /// `integrations_recommend`): at most six, none of them connected.
    public func recommendedIntegrations(agentID: String) async throws -> [IntegrationRecommendation] {
        struct P: Encodable { var agentId: String }
        return try await rpc().call("integrations.recommend", P(agentId: agentID), as: [IntegrationRecommendation].self)
    }

    /// The tools the last successful check of a service listed, with their annotations (`integrations.tools`).
    public func integrationTools(_ id: String) async throws -> [IntegrationTool] {
        struct P: Encodable { var id: String }
        return try await rpc().call("integrations.tools", P(id: id), as: [IntegrationTool].self)
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

/// One suggestion of `integrations.recommend`.
public struct IntegrationRecommendation: Decodable, Sendable, Hashable, Identifiable {
    public var templateId: String
    /// A key of the app's text, `recommend.reason.<name>`.
    public var reasonKey: String
    /// The file that showed it, relative to the agent's folder.
    public var evidence: String

    public var id: String { templateId }

    public init(templateId: String, reasonKey: String, evidence: String) {
        self.templateId = templateId
        self.reasonKey = reasonKey
        self.evidence = evidence
    }
}

// MARK: - browser sign-in (feature `integrations_oauth`)

extension ServerModel: OAuthServer {
    public var oauthServerID: UUID { id }

    public func oauthBegin(_ target: OAuthBeginTarget) async throws -> OAuthBegun {
        struct P: Encodable {
            var integration: String?
            var draft: NewIntegration?
        }
        let params: P
        switch target {
        case .existing(let id): params = P(integration: id)
        case .draft(let draft): params = P(draft: draft)
        }
        return try await rpc().call("integrations.oauth_begin", params, as: OAuthBegun.self, timeout: .seconds(30))
    }

    public func oauthComplete(state: String, code: String, iss: String?) async throws -> OAuthCompleted {
        struct P: Encodable {
            var state: String
            var code: String
            var iss: String?
        }
        return try await rpc().call(
            "integrations.oauth_complete", P(state: state, code: code, iss: iss), as: OAuthCompleted.self,
            timeout: .seconds(30))
    }

    public func oauthCancel(state: String) async {
        struct P: Encodable { var state: String }
        struct Reply: Decodable { var cancelled: Bool }
        _ = try? await rpc().call("integrations.oauth_cancel", P(state: state), as: Reply.self)
    }

    /// How each browser sign-in stands, by integration id. Empty for a daemon without the feature.
    public func oauthStatuses() async throws -> [OAuthStatus] {
        guard supports("integrations_oauth") else { return [] }
        struct Reply: Decodable { var integrations: [OAuthStatus] }
        return try await rpc().call("integrations.oauth_status", NoParams(), as: Reply.self).integrations
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
