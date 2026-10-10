import Foundation
import Testing

@testable import BanditoKit

/// `template_update` of `integrations.list`, `updates` of `skills.catalog`, `integrations.update_from_template` and
/// `integrations.recommend`.
@MainActor
@Suite struct MarketUpdatesWireTests {
    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    @Test func anIntegrationReadsItsTemplateUpdate() throws {
        let versions = try decode(
            Integration.self,
            #"{"id":"i","name":"x","kind":"stdio","command":"npx","template_update":{"from":"1.2.0","to":"1.3.0"}}"#)
        #expect(versions.templateUpdate == TemplateUpdate(from: "1.2.0", to: "1.3.0"))
        #expect(versions.templateUpdate?.isNewAddress == false)
        let moved = try decode(
            Integration.self, #"{"id":"i","name":"x","kind":"http","url":"https://a","template_update":{"from":null,"to":null}}"#)
        #expect(moved.templateUpdate?.isNewAddress == true)
        let none = try decode(Integration.self, #"{"id":"i","name":"x","kind":"http"}"#)
        #expect(none.templateUpdate == nil)
        // A broken field does not hide the row.
        let broken = try decode(Integration.self, #"{"id":"i","name":"x","kind":"http","template_update":5}"#)
        #expect(broken.templateUpdate == nil)
    }

    @Test func aSkillReadsWhereItIsBehind() throws {
        let skill = try decode(
            SkillEntry.self,
            #"{"id":"s","name":"s","installed":{"user":true,"projects":["a"]},"updates":{"user":false,"projects":["a"]}}"#)
        #expect(!skill.updates.user)
        #expect(skill.updates.projects == ["a"])
        let old = try decode(SkillEntry.self, #"{"id":"s","name":"s"}"#)
        #expect(!old.updates.user && old.updates.projects.isEmpty)
    }

    @Test func recommendationsDecode() throws {
        let list = try decode(
            [IntegrationRecommendation].self,
            #"[{"template_id":"vercel","reason_key":"recommend.reason.nextPackage","evidence":"package.json"}]"#)
        #expect(list.first?.templateId == "vercel")
        #expect(list.first?.reasonKey == "recommend.reason.nextPackage")
        #expect(list.first?.evidence == "package.json")
    }

    @Test func theCallsUseTheirMethodsAndParams() async throws {
        let row = #"{"id":"i1","name":"x","kind":"stdio","command":"npx"}"#
        let fake = FakeTransport(handlers: daemonHandlers(extra: [
            "integrations.update_from_template": { _ in row },
            "integrations.recommend": { _ in #"[{"template_id":"github","reason_key":"recommend.reason.gitRemoteGithub","evidence":".git/config"}]"# },
        ]))
        let (model, _) = makeModel([fake])
        await model.connect()
        _ = try await model.updateIntegrationFromTemplate("i1")
        let found = try await model.recommendedIntegrations(agentID: "a1")
        #expect(found.map(\.templateId) == ["github"])
        let texts = await fake.sentTexts()
        let update = try #require(JSONRPC.requests(of: "integrations.update_from_template", in: texts).first)
        #expect(try #require(JSONRPC.parse(update)).paramsJSON.contains("\"id\":\"i1\""))
        let recommend = try #require(JSONRPC.requests(of: "integrations.recommend", in: texts).first)
        #expect(try #require(JSONRPC.parse(recommend)).paramsJSON.contains("\"agent_id\":\"a1\""))
        await model.disconnect()
    }
}
