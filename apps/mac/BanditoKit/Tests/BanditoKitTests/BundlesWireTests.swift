import Foundation
import Testing

@testable import BanditoKit

/// The wire of `agents.bundles` and `agents.create_bundle`: the sets, the answer per template, and the body of the
/// request. The samples follow docs/ARCHITECTURE.md (#agent-bundles).
@MainActor
@Suite struct BundlesWireTests {
    nonisolated static let bundleJSON = ##"""
        {"id":"startup-team","name_en":"Startup team","name_ru":"Команда стартапа",
         "description_en":"A small team.","description_ru":"Небольшая команда.",
         "l10n":{"de":{"name":"Startup-Team","description":"Ein Team."},
                 "pt-BR":{"name":"Equipe de startup","description":"Uma equipe."}},
         "icon":"person.3.fill","accent":"#7388B0",
         "templates":["task-manager","code-reviewer"],"category":"business"}
        """##

    nonisolated static let creationJSON = ##"""
        {"agents":[
           {"template_id":"task-manager","agent":{"id":"a1","name":"Менеджер задач","runtime":"claude","cwd":"/x"}},
           {"template_id":"code-reviewer","error":"unknown runtime nope"},
           {"template_id":"docs-writer","agent":{"id":"a2","name":"Docs","runtime":"claude","cwd":"/y"},
            "error":"schedule 1: cron refused"}],
         "missing_integrations":[{"id":"github","required":true},{"id":"linear","required":false}]}
        """##

    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try RPCClient.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test func bundleDecodesWithTheAppsDecoder() throws {
        let b = try decode(AgentBundle.self, Self.bundleJSON)
        #expect(b.id == "startup-team")
        #expect(b.icon == "person.3.fill")
        #expect(b.accent == "#7388B0")
        #expect(b.templates == ["task-manager", "code-reviewer"])
        #expect(b.category == "business")
    }

    @Test func bundleTextFollowsTheAppLanguage() throws {
        let b = try decode(AgentBundle.self, Self.bundleJSON)
        #expect(b.name(languageCode: "ru") == "Команда стартапа")
        #expect(b.description(languageCode: "ru-RU") == "Небольшая команда.")
        #expect(b.name(languageCode: "de") == "Startup-Team")
        #expect(b.description(languageCode: "de") == "Ein Team.")
        #expect(b.name(languageCode: "pt_br") == "Equipe de startup")
        #expect(b.name(languageCode: "en") == "Startup team")
        // A language the catalog does not have reads English.
        #expect(b.name(languageCode: "xx") == "Startup team")
        #expect(b.description(languageCode: "ja") == "A small team.")
    }

    @Test func bundleSurvivesMissingAndBrokenOptionalFields() throws {
        let bare = try decode(AgentBundle.self, #"{"id":"x","name_en":"X"}"#)
        #expect(bare.name(languageCode: "ru") == "X")
        #expect(bare.templates.isEmpty)
        #expect(bare.category == "personal")
        #expect(bare.icon == "square.stack.3d.up")
        let broken = try decode(AgentBundle.self, #"{"id":"x","name_en":"X","l10n":{"de":5}}"#)
        #expect(broken.l10n.isEmpty)
        #expect(broken.name(languageCode: "de") == "X")
    }

    @Test func creationDecodesEachTemplatesAnswer() throws {
        let made = try decode(BundleCreation.self, Self.creationJSON)
        #expect(made.agents.map(\.templateId) == ["task-manager", "code-reviewer", "docs-writer"])
        #expect(made.agents[0].agent?.id == "a1")
        #expect(made.agents[0].error == nil)
        #expect(made.agents[1].agent == nil)
        #expect(made.agents[1].error == "unknown runtime nope")
        // An agent that exists, with a step after it that failed.
        #expect(made.agents[2].agent?.name == "Docs")
        #expect(made.agents[2].error == "schedule 1: cron refused")
        #expect(made.missingIntegrations == [
            MissingIntegration(id: "github", required: true),
            MissingIntegration(id: "linear", required: false),
        ])
    }

    @Test func emptyCreationAnswerDecodesToNothing() throws {
        let bare = try decode(BundleCreation.self, "{}")
        #expect(bare.agents.isEmpty)
        #expect(bare.missingIntegrations.isEmpty)
    }

    @Test func newBundleEncodesSnakeCaseAndLeavesOutWhatIsNotSet() throws {
        let body = try json(NewBundle(bundleId: "startup-team", language: "ru", runtime: "claude"))
        #expect(body["bundle_id"] as? String == "startup-team")
        #expect(body["language"] as? String == "ru")
        #expect(body["runtime"] as? String == "claude")
        #expect(body["workspace_id"] == nil)

        let plain = try json(NewBundle(bundleId: "devops", language: "de"))
        #expect(plain["runtime"] == nil)
        #expect(plain["bundle_id"] as? String == "devops")
        #expect(plain["language"] as? String == "de")
    }
}
