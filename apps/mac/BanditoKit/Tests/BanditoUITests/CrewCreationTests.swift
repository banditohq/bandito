import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// A server that can be told to fail on the way back (the agents exist but the answer is lost), or before anything is made.
@MainActor
private final class FakeCrewServer: CrewMaking {
    var agents: [Agent] = []
    var folders: [String] = []
    var folderFails = false
    /// What the next `createBundle` does: make every asked template, then throw (a lost answer) or return normally.
    var bundleBehaviour: Behaviour = .answers
    var requests: [NewBundle] = []
    var agentBehaviour: Behaviour = .answers
    var agentRequests: [NewAgent] = []
    private var counter = 0

    enum Behaviour {
        case answers
        /// Makes the agents, then the answer is lost.
        case madeButLost
        /// Makes the first `count` agents of the request, with the rest failing inside the answer.
        case partial(Int)
        /// Nothing is made and the request throws.
        case fails
    }

    struct Boom: Error {}

    func ensureFolder(_ path: String) async throws {
        if folderFails { throw Boom() }
        folders.append(path)
    }

    func readAgentsNow() async throws {}

    private func make(name: String, templateID: String?, cwd: String) -> Agent {
        counter += 1
        let agent = Agent(id: "a\(counter)", name: name, runtime: .claude, cwd: cwd, templateId: templateID)
        agents.append(agent)
        return agent
    }

    func createBundle(_ new: NewBundle) async throws -> BundleCreation {
        requests.append(new)
        let wanted = new.templates ?? []
        switch bundleBehaviour {
        case .answers:
            return BundleCreation(agents: wanted.map { BundleEntry(templateId: $0, agent: make(name: $0, templateID: $0, cwd: new.cwd ?? "")) })
        case .madeButLost:
            for id in wanted { _ = make(name: id, templateID: id, cwd: new.cwd ?? "") }
            throw Boom()
        case .partial(let count):
            var entries: [BundleEntry] = []
            for (index, id) in wanted.enumerated() {
                if index < count {
                    entries.append(BundleEntry(templateId: id, agent: make(name: id, templateID: id, cwd: new.cwd ?? "")))
                } else {
                    entries.append(BundleEntry(templateId: id, error: "no"))
                }
            }
            return BundleCreation(agents: entries)
        case .fails:
            throw Boom()
        }
    }

    func createAgent(_ new: NewAgent) async throws -> Agent {
        agentRequests.append(new)
        switch agentBehaviour {
        case .answers, .partial:
            return make(name: new.name, templateID: nil, cwd: new.cwd)
        case .madeButLost:
            _ = make(name: new.name, templateID: nil, cwd: new.cwd)
            throw Boom()
        case .fails:
            throw Boom()
        }
    }
}

@MainActor
@Suite struct CrewCreationTests {
    private func template(_ id: String) -> BotTemplate {
        BotTemplate(id: id, nameEn: id, nameRu: id)
    }

    private func team(_ server: FakeCrewServer, ids: [String] = ["t1", "t2", "t3"]) -> TeamCreation {
        let bundle = AgentBundle(id: "web-project", nameEn: "Web", nameRu: "Веб", templates: ids)
        return TeamCreation(
            server: server, bundle: bundle, members: ids.map(template), runtime: .claude, model: nil, languageCode: "en",
            describe: { _ in UserFacingMessage(text: "failed") })
    }

    private func make(_ creation: TeamCreation) async -> Bool {
        await creation.create(folder: "/home/me/projects/web", makeFolder: true, items: [], enabled: [])
    }

    @Test func aCleanRunMakesEveryAgentOnceAndTheFolderOnce() async {
        let server = FakeCrewServer()
        let creation = team(server)
        let done = await make(creation)
        #expect(done)
        #expect(creation.isComplete)
        #expect(server.agents.count == 3)
        #expect(server.folders == ["/home/me/projects/web"])
        #expect(creation.firstAgent?.id == "a1")
        #expect(creation.failure == nil)
        // A second tap changes nothing.
        _ = await make(creation)
        #expect(server.agents.count == 3)
        #expect(server.requests.count == 1)
    }

    @Test func aLostAnswerDoesNotMakeTheTeamTwice() async {
        let server = FakeCrewServer()
        server.bundleBehaviour = .madeButLost
        let creation = team(server)
        let first = await make(creation)
        // The agents exist although the request failed: they are counted from the list, by their template.
        #expect(first)
        #expect(creation.isComplete)
        #expect(server.agents.count == 3)
        let again = await make(creation)
        #expect(again)
        #expect(server.agents.count == 3)
        #expect(server.requests.count == 1)
    }

    @Test func aPartialAnswerRetriesOnlyTheMissingOnesInTheSameFolder() async {
        let server = FakeCrewServer()
        server.bundleBehaviour = .partial(1)
        let creation = team(server)
        let first = await make(creation)
        #expect(!first)
        #expect(creation.made.keys.sorted() == ["t1"])
        #expect(creation.failure?.canRetry == true)
        #expect(server.agents.count == 1)

        server.bundleBehaviour = .answers
        let second = await creation.create(folder: "/home/me/projects/OTHER", makeFolder: true, items: [], enabled: [])
        #expect(second)
        #expect(server.requests.count == 2)
        // Only the two missing positions were asked for, and in the first attempt's folder.
        #expect(server.requests[1].templates == ["t2", "t3"])
        #expect(server.requests[1].cwd == "/home/me/projects/web")
        #expect(server.agents.count == 3)
        // The folder was made once, by the first attempt.
        #expect(server.folders == ["/home/me/projects/web"])
    }

    @Test func anEntryWithAnAgentAndAnErrorCountsAsMade() async {
        let bundle = AgentBundle(id: "b", nameEn: "B", nameRu: "B", templates: ["t1"])
        // A schedule failed after the agent was made: the entry has both.
        @MainActor final class Server: CrewMaking {
            var agents: [Agent] = []
            func ensureFolder(_ path: String) async throws {}
            func readAgentsNow() async throws {}
            func createAgent(_ new: NewAgent) async throws -> Agent { throw FakeCrewServer.Boom() }
            func createBundle(_ new: NewBundle) async throws -> BundleCreation {
                BundleCreation(agents: [
                    BundleEntry(
                        templateId: "t1", agent: Agent(id: "x", name: "X", runtime: .claude, cwd: "/p", templateId: "t1"),
                        error: "schedule failed")
                ])
            }
        }
        let creation = TeamCreation(
            server: Server(), bundle: bundle, members: [template("t1")], runtime: .claude, model: nil, languageCode: "en")
        #expect(await creation.create(folder: "/p", makeFolder: false, items: [], enabled: []))
        #expect(creation.made["t1"]?.id == "x")
    }

    @Test func aFolderThePersonPickedIsNotMade() async {
        let server = FakeCrewServer()
        let creation = team(server)
        _ = await creation.create(folder: "/srv/mine", makeFolder: false, items: [], enabled: [])
        #expect(server.folders.isEmpty)
        #expect(server.requests.first?.cwd == "/srv/mine")
    }

    @Test func aFailedFolderMakesNothingAndTheRetryTriesAgain() async {
        let server = FakeCrewServer()
        server.folderFails = true
        let creation = team(server)
        #expect(await make(creation) == false)
        #expect(server.requests.isEmpty)
        #expect(creation.failure?.text == "failed")
        server.folderFails = false
        #expect(await make(creation))
        #expect(server.folders.count == 1)
        #expect(server.agents.count == 3)
    }

    @Test func aRequestThatFailsWithNothingMadeCanBeRepeated() async {
        let server = FakeCrewServer()
        server.bundleBehaviour = .fails
        let creation = team(server)
        #expect(await make(creation) == false)
        #expect(server.agents.isEmpty)
        #expect(creation.failure != nil)
        server.bundleBehaviour = .answers
        #expect(await make(creation))
        #expect(server.agents.count == 3)
        #expect(server.requests.last?.templates == ["t1", "t2", "t3"])
    }

    @Test func aNewAgentWithTheSameNameIsMatchedWhenTheTemplateIsUnknown() async {
        let server = FakeCrewServer()
        server.bundleBehaviour = .fails
        let creation = team(server)
        // An agent with the name of position "t2" was on the server before the attempt. It is in the snapshot taken
        // before the request, so it is not ours and must not count as made.
        server.agents.append(Agent(id: "late", name: "t2", runtime: .claude, cwd: "/p"))
        #expect(await make(creation) == false)
        #expect(creation.made.isEmpty)
    }

    @Test func oneAgentIsMadeOnceAfterALostAnswer() async {
        let server = FakeCrewServer()
        server.agentBehaviour = .madeButLost
        let creation = OneAgentCreation(server: server, describe: { _ in UserFacingMessage(text: "failed") })
        let build: (String) -> NewAgent = { NewAgent(name: "Forge", runtime: .claude, cwd: $0) }
        #expect(await creation.create(folder: "/p/forge", makeFolder: true, build: build))
        #expect(creation.agent?.name == "Forge")
        #expect(await creation.create(folder: "/p/forge", makeFolder: true, build: build))
        #expect(server.agents.count == 1)
        #expect(server.agentRequests.count == 1)
        #expect(server.folders == ["/p/forge"])
    }

    @Test func oneAgentThatFailedCleanlyIsRetriedInTheSameFolder() async {
        let server = FakeCrewServer()
        server.agentBehaviour = .fails
        let creation = OneAgentCreation(server: server, describe: { _ in UserFacingMessage(text: "failed") })
        let build: (String) -> NewAgent = { NewAgent(name: "Forge", runtime: .claude, cwd: $0) }
        #expect(await creation.create(folder: "/p/forge", makeFolder: true, build: build) == false)
        #expect(creation.failure?.text == "failed")
        server.agentBehaviour = .answers
        #expect(await creation.create(folder: "/p/other", makeFolder: true, build: build))
        #expect(server.agentRequests.last?.cwd == "/p/forge")
        #expect(server.agents.count == 1)
        #expect(server.folders == ["/p/forge"])
    }
}

@Suite struct FirstTaskSuggestionsTests {
    @Test func everyTeamGetsFourDistinctPromptsAndAnUnknownTeamTheGeneralFour() {
        for id in ["web-project", "server-duty", "morning-summary", "docs-upkeep", nil, "something-new"] {
            let prompts = FirstTaskSuggestions.prompts(forTeam: id)
            #expect(prompts.count == 4)
            #expect(Set(prompts).count == 4)
        }
    }

    @Test func theSuggestionsFitTheCrew() {
        #expect(FirstTaskSuggestions.prompts(forTeam: "server-duty").contains(.disk))
        #expect(FirstTaskSuggestions.prompts(forTeam: "web-project").contains(.tests))
        #expect(FirstTaskSuggestions.prompts(forTeam: "docs-upkeep").first == .docs)
        #expect(!FirstTaskSuggestions.prompts(forTeam: "web-project").contains(.disk))
    }

    @Test func everyPromptHasTextInEveryLanguageOfTheCatalog() {
        for prompt in FirstTaskSuggestions.Prompt.allCases {
            #expect(!prompt.text.isEmpty)
        }
    }
}

@Suite struct NightShiftTests {
    @Test func theCardSleepsUntilTheNextChangeNotPerFrame() {
        var t = 0.0
        var wakes = 0
        while t < NightShift.cycleSeconds - 0.001 {
            t += NightShift.secondsToNextChange(from: t)
            wakes += 1
            if wakes > 20 { break }
        }
        // Four events, the morning and the end of the cycle: six wakes, never one per tick.
        #expect(wakes == 6)
    }

    @Test func theStateFollowsTheCycle() {
        #expect(NightShift.state(at: 0) == (0, false))
        #expect(NightShift.state(at: NightShift.firstEventAt + 0.01).lit == 1)
        #expect(NightShift.state(at: NightShift.morningAt + 0.01) == (4, true))
        #expect(NightShift.state(at: NightShift.cycleSeconds + 0.1) == (0, false))
    }
}
