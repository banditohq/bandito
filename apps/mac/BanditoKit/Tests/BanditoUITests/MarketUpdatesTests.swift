import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Updates of skills and services, and the row of suggestions for a project.
@Suite struct MarketUpdatesTests {
    private func agent(_ id: String) throws -> Agent {
        try RPCClient.decoder.decode(Agent.self, from: Data(#"{"id":"\#(id)","name":"N\#(id)","runtime":"claude","cwd":"/x"}"#.utf8))
    }

    private func template(_ id: String, url: String? = nil) -> IntegrationCatalogEntry {
        IntegrationCatalogEntry(
            id: id, name: id.capitalized, descriptionEn: "", descriptionRu: "", kind: url == nil ? .stdio : .http,
            url: url, docsUrl: "", icon: "")
    }

    // MARK: updates

    @Test func theUpdateLineShowsVersionsOrANewAddress() {
        #expect(UpdateLine(TemplateUpdate(from: "1.0.0", to: "1.1.0")) == .versions(from: "1.0.0", to: "1.1.0"))
        #expect(UpdateLine(TemplateUpdate(from: nil, to: nil)) == .newAddress)
        #expect(UpdateLine(TemplateUpdate(from: "", to: " ")) == .newAddress)
        #expect(UpdateLine(TemplateUpdate(from: "1.0.0", to: nil)) == .plain)
        #expect(UpdateLine(TemplateUpdate(from: "1.0.0", to: "1.1.0")).text.contains("1.0.0"))
        #expect(UpdateLine(TemplateUpdate(from: "1.0.0", to: "1.1.0")).text.contains("1.1.0"))
    }

    @Test func aSkillIsUpdatedWhereItIsInstalledAndBehind() {
        let skill = SkillEntry(
            id: "s", name: "s", installed: SkillPlaces(user: true, projects: ["a", "b"]),
            updates: SkillPlaces(user: true, projects: ["b", "gone"]))
        #expect(SkillLogic.updateTargets(skill) == [.everyone, .agent("b")])
        #expect(SkillLogic.hasUpdate(skill))
        let current = SkillEntry(id: "s", name: "s", installed: SkillPlaces(user: true))
        #expect(SkillLogic.updateTargets(current).isEmpty)
        #expect(!SkillLogic.hasUpdate(current))
        // A flag for a place the skill is not installed in is ignored.
        let stray = SkillEntry(id: "s", name: "s", updates: SkillPlaces(user: true))
        #expect(!SkillLogic.hasUpdate(stray))
        // The update is the install in the same scope.
        #expect(SkillLogic.updateTargets(skill).map(\.scope) == [.user, .agent("b")])
    }

    // MARK: suggestions

    @Test func suggestionsDropWhatIsConnectedUnknownOrRepeated() {
        let catalog = [template("github"), template("vercel"), template("sentry", url: "https://mcp.sentry.dev/mcp")]
        let list = [
            IntegrationRecommendation(templateId: "github", reasonKey: "recommend.reason.gitRemoteGithub", evidence: ".git/config"),
            IntegrationRecommendation(templateId: "nope", reasonKey: "k", evidence: "x"),
            IntegrationRecommendation(templateId: "vercel", reasonKey: "recommend.reason.nextPackage", evidence: "package.json"),
            IntegrationRecommendation(templateId: "vercel", reasonKey: "recommend.reason.vercelJson", evidence: "vercel.json"),
            IntegrationRecommendation(templateId: "sentry", reasonKey: "recommend.reason.sentryPackage", evidence: "package.json"),
        ]
        let connected = [Integration(id: "i", name: "my sentry", kind: .http, url: "https://mcp.sentry.dev/mcp")]
        let items = RecommendationLogic.items(list, catalog: catalog, integrations: connected)
        #expect(items.map(\.id) == ["github", "vercel"])
        #expect(items[1].reasonKey == "recommend.reason.nextPackage")
        #expect(items[1].evidence == "package.json")
    }

    @Test func atMostSixSuggestionsShow() {
        let catalog = (0..<9).map { template("t\($0)") }
        let list = catalog.map { IntegrationRecommendation(templateId: $0.id, reasonKey: "k", evidence: "e") }
        #expect(RecommendationLogic.items(list, catalog: catalog, integrations: []).count == 6)
    }

    @Test func everyDocumentedReasonHasItsOwnWords() {
        let other = RecommendationLogic.reasonText("recommend.reason.unheardOf")
        #expect(!other.isEmpty)
        var seen = Set<String>()
        for key in RecommendationLogic.knownKeys {
            let text = RecommendationLogic.reasonText(key)
            #expect(text != other, "\(key) falls to the generic text")
            #expect(text != key)
            #expect(seen.insert(text).inserted, "\(key) repeats another text")
        }
        #expect(RecommendationLogic.knownKeys.count == 17)
    }

    @Test func theRowIsForTheSelectedThenTheLastOpenedThenTheFirstAgent() throws {
        let agents = [try agent("a"), try agent("b"), try agent("c")]
        #expect(RecommendationLogic.agent(selected: "b", remembered: "c", agents: agents)?.id == "b")
        #expect(RecommendationLogic.agent(selected: "other-server", remembered: "c", agents: agents)?.id == "c")
        #expect(RecommendationLogic.agent(selected: nil, remembered: nil, agents: agents)?.id == "a")
        #expect(RecommendationLogic.agent(selected: nil, remembered: nil, agents: []) == nil)
    }

    @Test func aClosedRowStaysClosedForThatAgentOnThatServerOnly() throws {
        let store = try #require(UserDefaults(suiteName: "MarketUpdatesTests.\(UUID().uuidString)"))
        #expect(!RecommendationStore.isHidden(server: "s1", agent: "a", defaults: store))
        RecommendationStore.hide(server: "s1", agent: "a", defaults: store)
        RecommendationStore.hide(server: "s1", agent: "a", defaults: store)
        #expect(RecommendationStore.isHidden(server: "s1", agent: "a", defaults: store))
        #expect(!RecommendationStore.isHidden(server: "s1", agent: "b", defaults: store))
        #expect(!RecommendationStore.isHidden(server: "s2", agent: "a", defaults: store))
        #expect(store.stringArray(forKey: RecommendationStore.key)?.count == 1)
    }
}
