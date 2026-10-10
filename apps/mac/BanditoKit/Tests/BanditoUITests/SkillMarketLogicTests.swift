import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The Skills page: the filter and the search, the state of a skill from the catalog answer, and where it can go.
@Suite struct SkillMarketLogicTests {
    private func skill(
        _ id: String, category: String = "dev", description: String = "", installed: SkillPlaces = SkillPlaces(),
        conflicts: SkillPlaces = SkillPlaces()
    ) -> SkillEntry {
        SkillEntry(
            id: id, name: id, publisher: "obra", descriptionEn: description, descriptionRu: description + " ру",
            category: category, installed: installed, conflicts: conflicts)
    }

    private func agent(_ id: String, _ name: String) throws -> Agent {
        try RPCClient.decoder.decode(
            Agent.self, from: Data(#"{"id":"\#(id)","name":"\#(name)","runtime":"claude","cwd":"/x"}"#.utf8))
    }

    // MARK: filter and search

    @Test func categoriesComeInTheSidebarOrder() {
        let list = [skill("a", category: "design"), skill("b", category: "dev"), skill("c", category: "mystery"), skill("d", category: "ops")]
        #expect(SkillLogic.categories(in: list) == ["dev", "ops", "design", "mystery"])
    }

    @Test func theInstalledFilterKeepsWhatIsInstalledAnywhere() {
        let list = [
            skill("none"),
            skill("user", installed: SkillPlaces(user: true)),
            skill("agent", installed: SkillPlaces(projects: ["a1"])),
            skill("blocked", conflicts: SkillPlaces(user: true)),
        ]
        #expect(SkillLogic.visible(list, filter: .installed, query: "", languageCode: "en").map(\.id) == ["user", "agent"])
        #expect(SkillLogic.visible(list, filter: .all, query: "", languageCode: "en").count == 4)
    }

    @Test func theSearchReadsTheNameAndTheDescriptionInBothLanguages() {
        let list = [
            skill("systematic-debugging", description: "Find the root cause."),
            skill("commit", category: "dev", description: "Write a commit message."),
        ]
        func ids(_ query: String, _ language: String) -> [String] {
            SkillLogic.visible(list, filter: .all, query: query, languageCode: language).map(\.id)
        }
        #expect(ids("DEBUG", "en") == ["systematic-debugging"])
        #expect(ids("root cause", "ru") == ["systematic-debugging"])
        #expect(ids("ру", "ru") == ["systematic-debugging", "commit"])
        #expect(ids("commit", "de") == ["commit"])
        #expect(ids("zzz", "en").isEmpty)
        #expect(SkillLogic.visible(list, filter: .category("ops"), query: "", languageCode: "en").isEmpty)
    }

    // MARK: state

    @Test func theStateComesFromTheCatalogAnswer() throws {
        let raw = #"{"id":"commit","name":"commit","installed":{"user":true,"projects":["a1","a2"]},"conflicts":{"user":false,"projects":["a3"]}}"#
        let entry = try RPCClient.decoder.decode(SkillEntry.self, from: Data(raw.utf8))
        let state = SkillLogic.State(entry)
        #expect(state.installedForEveryone)
        #expect(state.installedAgents == ["a1", "a2"])
        #expect(state.conflictAgents == ["a3"])
        #expect(state.isInstalled)
        #expect(state.hasConflict)
        // Installed for the server wins over the count of agents.
        #expect(state.badge == .installed)
    }

    @Test func theBadgeIsInstalledOrACountOrNothing() {
        #expect(SkillLogic.State(skill("s", installed: SkillPlaces(user: true))).badge == .installed)
        #expect(SkillLogic.State(skill("s", installed: SkillPlaces(projects: ["a", "b"]))).badge == .onAgents(2))
        let bare = SkillLogic.State(skill("s"))
        #expect(bare.badge == .none)
        #expect(!bare.isInstalled)
        #expect(!bare.hasConflict)
    }

    @Test func aConflictIsNotInstalledAndBlocksItsPlace() {
        let entry = skill("s", conflicts: SkillPlaces(user: true, projects: ["a3"]))
        let state = SkillLogic.State(entry)
        #expect(!state.isInstalled)
        #expect(state.hasConflict)
        #expect(SkillLogic.block(.everyone, for: entry) == .conflict)
        #expect(SkillLogic.block(.agent("a3"), for: entry) == .conflict)
        #expect(SkillLogic.block(.agent("a4"), for: entry) == nil)
    }

    // MARK: targets

    @Test func anInstalledPlaceIsBlockedAndTheDefaultTargetMovesOn() throws {
        let agents = [try agent("a1", "One"), try agent("a2", "Two")]
        let free = skill("s")
        #expect(SkillLogic.defaultTarget(for: free, agents: agents) == .everyone)

        let everyoneTaken = skill("s", installed: SkillPlaces(user: true, projects: ["a1"]))
        #expect(SkillLogic.block(.everyone, for: everyoneTaken) == .installed)
        #expect(SkillLogic.defaultTarget(for: everyoneTaken, agents: agents) == .agent("a2"))

        let allTaken = skill("s", installed: SkillPlaces(user: true, projects: ["a1", "a2"]))
        #expect(SkillLogic.defaultTarget(for: allTaken, agents: agents) == nil)
        #expect(!SkillLogic.canInstall(allTaken, agents: agents))
    }

    @Test func aConflictAtTheServerStillAllowsAnAgent() throws {
        let agents = [try agent("a1", "One")]
        let entry = skill("s", conflicts: SkillPlaces(user: true))
        #expect(SkillLogic.defaultTarget(for: entry, agents: agents) == .agent("a1"))
        // No agents and the server's place taken: nowhere to install.
        #expect(SkillLogic.defaultTarget(for: entry, agents: []) == nil)
        #expect(SkillLogic.defaultTarget(for: skill("s"), agents: []) == .everyone)
    }

    @Test func aTargetMapsToTheDaemonsScope() {
        #expect(SkillLogic.Target.everyone.scope == .user)
        #expect(SkillLogic.Target.agent("a1").scope == .agent("a1"))
        #expect(SkillsMarketModel.busyKey("s", .everyone) != SkillsMarketModel.busyKey("s", .agent("a1")))
    }

    @Test func anAgentThatIsGoneIsNamedByItsId() throws {
        #expect(SkillLogic.agentName("a1", agents: [try agent("a1", "One")]) == "One")
        #expect(SkillLogic.agentName("gone", agents: []) == "gone")
    }

    // MARK: failures

    @Test func theDaemonsReasonsBecomeFailuresThePersonCanActOn() {
        func error(_ reason: String) -> RPCError {
            RPCError(code: -32027, message: "skill failed", data: .object(["reason": .string(reason)]))
        }
        #expect(SkillLogic.failure(for: error("exists_not_ours")) == .folderNotOurs)
        #expect(SkillLogic.failure(for: error("not_ours")) == .folderNotOurs)
        #expect(SkillLogic.failure(for: error("not_installed")) == .notInstalled)
        #expect(SkillLogic.failure(for: error("unsafe_path")) == .unsafePath)
        #expect(SkillLogic.failure(for: error("io")) == nil)
        #expect(SkillLogic.failure(for: RPCError(code: -32602, message: "bad")) == nil)
    }
}
