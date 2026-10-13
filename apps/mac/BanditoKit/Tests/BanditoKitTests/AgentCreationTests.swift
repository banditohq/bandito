import Foundation
import Testing

@testable import BanditoKit

/// A server that makes what it is asked for and records it. Flags make it fail the way a daemon does; the clock of the
/// agents it makes is `clockOffset` away from this machine's (the server's clock may be ahead or behind).
@MainActor
private final class FakeServer: AgentCreationServer {
    var agents: [Agent] = []
    var bundleRequests: [NewBundle] = []
    var agentRequests: [NewAgent] = []
    var readCount = 0
    /// Templates whose entry has an agent and an error (a schedule failed after the agent was made).
    var entryErrors: Set<String> = []
    /// Templates whose entry has an error and no agent.
    var failingTemplates: Set<String> = []
    var losesBundleAnswer = false
    var failsBundleBeforeMaking = false
    /// How many of the next `readAgentsNow` calls fail (the connection is down).
    var readFailures = 0
    var emptyBundleAnswer = false
    var losesAgentAnswer = false
    var agentFailures = 0
    var clockOffset: Int64 = 0

    struct Boom: Error {}

    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) + clockOffset }

    func readAgentsNow() async throws {
        readCount += 1
        if readFailures > 0 {
            readFailures -= 1
            throw Boom()
        }
    }

    func createAgent(_ new: NewAgent) async throws -> Agent {
        agentRequests.append(new)
        if agentFailures > 0 {
            agentFailures -= 1
            throw Boom()
        }
        let agent = Agent(id: "one-\(agents.count + 1)", name: new.name, runtime: new.runtime, cwd: new.cwd, createdAt: now)
        agents.append(agent)
        if losesAgentAnswer { throw Boom() }
        return agent
    }

    func createBundle(_ new: NewBundle) async throws -> BundleCreation {
        bundleRequests.append(new)
        if failsBundleBeforeMaking { throw Boom() }
        if emptyBundleAnswer { return BundleCreation(agents: []) }
        var entries: [BundleEntry] = []
        for id in new.templates ?? [] {
            if failingTemplates.contains(id) {
                entries.append(BundleEntry(templateId: id, error: "could not be made"))
                continue
            }
            let agent = Agent(
                id: "b-\(agents.count + 1)", name: id, runtime: .claude, cwd: new.cwd ?? "/", createdAt: now, templateId: id)
            agents.append(agent)
            entries.append(BundleEntry(templateId: id, agent: agent, error: entryErrors.contains(id) ? "schedule failed" : nil))
        }
        if losesBundleAnswer { throw Boom() }
        return BundleCreation(agents: entries)
    }
}

@MainActor
@Suite struct AgentCreationTests {
    private let ids = ["t1", "t2", "t3"]
    private let texts = AgentCreationTexts(
        describe: { _ in "failed" }, partial: { "\($0) of \($1)" }, noRuntime: "no runtime", none: "nothing")

    private func bundle() -> AgentBundle {
        AgentBundle(id: "b", nameEn: "Team", nameRu: "Команда", templates: ids)
    }

    private func team(_ server: FakeServer, alreadyMade: [String: Agent] = [:]) -> TeamCreation {
        TeamCreation(
            server: server, bundle: bundle(), members: ids.map { BotTemplate(id: $0, nameEn: $0, nameRu: $0) },
            runtime: .claude, model: nil, languageCode: "en", texts: texts, alreadyMade: alreadyMade)
    }

    /// A folder maker that counts its calls and can fail.
    @MainActor private final class Folders {
        var calls = 0
        var fails = false
        func make() async throws -> String {
            calls += 1
            if fails { throw FakeServer.Boom() }
            return "/work/team"
        }
    }

    private func run(_ creation: TeamCreation, _ folders: Folders) async -> Bool {
        await creation.create(folder: { try await folders.make() }, items: [], enabled: [])
    }

    @Test func aCleanRunMakesEveryAgentOnceInOneFolder() async {
        let server = FakeServer()
        let folders = Folders()
        let creation = team(server)
        #expect(await run(creation, folders))
        #expect(creation.isComplete)
        #expect(creation.madeCount == 1)
        #expect(server.agents.count == 3)
        #expect(folders.calls == 1)
        #expect(creation.firstAgent?.name == "t1")
        // Another tap changes nothing.
        #expect(await run(creation, folders))
        #expect(server.bundleRequests.count == 1)
        #expect(creation.madeCount == 1)
    }

    @Test func aLostAnswerDoesNotMakeTheTeamTwice() async {
        let server = FakeServer()
        server.losesBundleAnswer = true
        let creation = team(server)
        #expect(await run(creation, Folders()))
        #expect(server.agents.count == 3)
        #expect(server.readCount == 1)
        #expect(await run(creation, Folders()))
        #expect(server.bundleRequests.count == 1)
    }

    @Test func anEntryWithAnAgentAndAnErrorCountsAsMade() async {
        let server = FakeServer()
        server.entryErrors = ["t2"]
        let creation = team(server)
        #expect(await run(creation, Folders()))
        #expect(creation.made["t2"] != nil)
        #expect(creation.problems["t2"] == "schedule failed")
        #expect(creation.result.agents.count == 3)
        #expect(creation.failure == nil)
    }

    @Test func aRetryMakesOnlyTheMissingAgentsInTheFirstFolderAndTheFolderOnce() async {
        let server = FakeServer()
        server.failingTemplates = ["t2"]
        let folders = Folders()
        let creation = team(server)
        #expect(await run(creation, folders) == false)
        #expect(creation.madeTemplateIDs == ["t1", "t3"])
        #expect(creation.failure == "could not be made")
        server.failingTemplates = []
        #expect(await run(creation, folders))
        #expect(server.bundleRequests[1].templates == ["t2"])
        #expect(server.bundleRequests[1].cwd == "/work/team")
        #expect(server.agents.count == 3)
        #expect(folders.calls == 1)
    }

    @Test func theServersClockDecidesNothing() async {
        for offset: Int64 in [-3_600_000 * 5, 0, 3_600_000 * 5] {
            let server = FakeServer()
            server.clockOffset = offset
            server.losesBundleAnswer = true
            let creation = team(server)
            #expect(await run(creation, Folders()), "offset \(offset)")
            #expect(server.agents.count == 3)
        }
    }

    @Test func anAgentThatWasThereBeforeTheAttemptIsNotTakenForTheTeamsOwnUnlessSeeded() async {
        let server = FakeServer()
        server.failsBundleBeforeMaking = true
        server.agents = [Agent(id: "old", name: "t2", runtime: .claude, cwd: "/p", templateId: "t2")]
        let creation = team(server)
        #expect(await run(creation, Folders()) == false)
        #expect(creation.made.isEmpty)
        #expect(creation.failure == "failed")
    }

    @Test func aTeamResumedFromTheServerMakesOnlyWhatIsMissing() async {
        let server = FakeServer()
        let there = Agent(id: "old1", name: "t1", runtime: .claude, cwd: "/p", templateId: "t1")
        server.agents = [there]
        let creation = team(server, alreadyMade: ["t1": there, "ghost": there])
        #expect(creation.madeTemplateIDs == ["t1"])
        #expect(await run(creation, Folders()))
        #expect(server.bundleRequests.first?.templates == ["t2", "t3"])
        #expect(server.agents.count == 3)
        #expect(creation.firstAgent?.id == "old1")
    }

    @Test func aFailedFolderMakesNothingAndTheRetryAsksForItAgain() async {
        let server = FakeServer()
        let folders = Folders()
        folders.fails = true
        let creation = team(server)
        #expect(await run(creation, folders) == false)
        #expect(server.bundleRequests.isEmpty)
        #expect(creation.folder == nil)
        folders.fails = false
        #expect(await run(creation, folders))
        #expect(folders.calls == 2)
    }

    @Test func aRequestThatFailsBeforeMakingAnythingCanBeRepeated() async {
        let server = FakeServer()
        server.failsBundleBeforeMaking = true
        let creation = team(server)
        #expect(await run(creation, Folders()) == false)
        #expect(creation.failure == "failed")
        server.failsBundleBeforeMaking = false
        #expect(await run(creation, Folders()))
        #expect(server.bundleRequests.last?.templates == ids)
    }

    @Test func oneAgentIsMadeOnceAfterALostAnswer() async {
        let server = FakeServer()
        server.losesAgentAnswer = true
        let creation = SingleAgentCreation(server: server, describe: { _ in "failed" })
        var folderCalls = 0
        let build: (String, String?) -> NewAgent = { folder, _ in NewAgent(name: "Forge", runtime: .claude, cwd: folder) }
        #expect(await creation.create(folder: { folderCalls += 1; return "/p/forge" }, build: build))
        #expect(await creation.create(folder: { folderCalls += 1; return "/p/forge" }, build: build))
        #expect(server.agents.count == 1)
        #expect(server.agentRequests.count == 1)
        #expect(folderCalls == 1)
        #expect(creation.madeCount == 1)
    }

    @Test func oneAgentAfterACleanFailureIsRetriedInTheSameFolderWithOneContainer() async {
        let server = FakeServer()
        server.agentFailures = 1
        let creation = SingleAgentCreation(server: server, describe: { _ in "failed" })
        var containers = 0
        let build: (String, String?) -> NewAgent = { folder, box in NewAgent(name: "Forge", runtime: .claude, cwd: folder, workspaceId: box) }
        let first = await creation.create(
            folder: { "/p/forge" }, workplace: { containers += 1; return "box-1" }, build: build)
        #expect(first == false)
        #expect(creation.failure == "failed")
        let second = await creation.create(
            folder: { "/p/other" }, workplace: { containers += 1; return "box-2" }, build: build)
        #expect(second)
        #expect(server.agentRequests.last?.cwd == "/p/forge")
        #expect(server.agentRequests.last?.workspaceId == "box-1")
        #expect(containers == 1)
        #expect(server.agents.count == 1)
    }

    @Test func aFailedContainerStopsTheAgentAndIsTriedAgain() async {
        let server = FakeServer()
        let creation = SingleAgentCreation(server: server, describe: { _ in "failed" })
        var tries = 0
        let build: (String, String?) -> NewAgent = { folder, box in NewAgent(name: "Forge", runtime: .claude, cwd: folder, workspaceId: box) }
        let first = await creation.create(
            folder: { "/p" }, workplace: { tries += 1; if tries == 1 { throw FakeServer.Boom() }; return "box" }, build: build)
        #expect(first == false)
        #expect(server.agentRequests.isEmpty)
        #expect(await creation.create(folder: { "/p" }, workplace: { tries += 1; return "box" }, build: build))
        #expect(server.agentRequests.first?.workspaceId == "box")
    }

    // MARK: unknown state (the read fails too)

    @Test func whenTheListCannotBeReadAfterAFailureTheRetryMakesNothingUntilItCan() async {
        let server = FakeServer()
        server.losesBundleAnswer = true
        server.readFailures = 2
        let creation = team(server)
        #expect(await run(creation, Folders()) == false)
        #expect(server.agents.count == 3)  // the daemon made them; we do not know
        #expect(creation.made.isEmpty)
        // Retry 1: the read fails again: no request goes out, the error is shown.
        #expect(await run(creation, Folders()) == false)
        #expect(server.bundleRequests.count == 1)
        #expect(creation.failure == "failed")
        // Retry 2: the read passes: the new agents are counted, nothing is made twice.
        #expect(await run(creation, Folders()))
        #expect(server.bundleRequests.count == 1)
        #expect(server.agents.count == 3)
        #expect(creation.isComplete)
    }

    @Test func afterTheListIsReadTheMissingAreMadeOnce() async {
        let server = FakeServer()
        server.failsBundleBeforeMaking = true
        server.readFailures = 1
        let creation = team(server)
        #expect(await run(creation, Folders()) == false)
        server.failsBundleBeforeMaking = false
        #expect(await run(creation, Folders()))
        #expect(server.bundleRequests.last?.templates == ids)
        #expect(server.agents.count == 3)
    }

    @Test func oneAgentWhoseAnswerAndListAreBothLostIsCountedAfterTheNextRead() async {
        let server = FakeServer()
        server.losesAgentAnswer = true
        server.readFailures = 1
        let creation = SingleAgentCreation(server: server, describe: { _ in "failed" })
        let build: (String, String?) -> NewAgent = { folder, _ in NewAgent(name: "Forge", runtime: .claude, cwd: folder) }
        #expect(await creation.create(folder: { "/p" }, build: build) == false)
        // The read fails again: nothing is made.
        server.readFailures = 1
        #expect(await creation.create(folder: { "/p" }, build: build) == false)
        #expect(server.agentRequests.count == 1)
        // The read passes: the agent the first request made is the one.
        #expect(await creation.create(folder: { "/p" }, build: build))
        #expect(server.agentRequests.count == 1)
        #expect(server.agents.count == 1)
        #expect(creation.agent?.name == "Forge")
    }

    @Test func anEmptyAnswerIsNotMadeAndSaysSo() async {
        let server = FakeServer()
        server.emptyBundleAnswer = true
        let creation = team(server)
        #expect(await run(creation, Folders()) == false)
        #expect(creation.failure == "nothing")
    }

    // MARK: kept across a closed sheet

    @Test func aPartialFailureClosedAndOpenedAgainContinuesWithoutDuplicates() async {
        let server = FakeServer()
        server.failingTemplates = ["t2"]
        let store = AgentCreationStore()
        let first = team(server)
        store.setTeam(first, for: "sheet:b")
        #expect(await run(first, Folders()) == false)
        // The sheet is closed and opened again: the store gives back the same creation with its progress.
        let again = try? #require(store.team("sheet:b"))
        #expect(again === first)
        #expect(again?.madeTemplateIDs == ["t1", "t3"])
        #expect(again?.failure != nil)
        server.failingTemplates = []
        #expect(await run(again!, Folders()))
        #expect(server.agents.count == 3)
        #expect(server.bundleRequests[1].templates == ["t2"])
        store.forgetTeam("sheet:b")
        #expect(store.team("sheet:b") == nil)
    }

    @Test func anAttemptRunningWhenTheSheetClosesFinishesAndItsResultIsThereOnTheNextOpen() async {
        let server = FakeServer()
        let store = AgentCreationStore()
        let creation = team(server)
        store.setTeam(creation, for: "sheet:b")
        // The sheet's task is not tied to the sheet: it runs to the end with nobody looking.
        let folders = Folders()
        let running = Task { await run(creation, folders) }
        _ = await running.value
        #expect(store.team("sheet:b")?.isComplete == true)
        #expect(store.team("sheet:b")?.result.agents.count == 3)
    }

    // MARK: ownership and keys

    @Test func theServerIsFreedAlthoughItKeepsItsCreations() {
        weak var weakServer: ServerModel?
        var creation: TeamCreation?
        do {
            let (server, _) = DemoDaemon.server(id: UUID(), name: "Demo", setup: DemoDaemonSetup())
            weakServer = server
            let made = TeamCreation(
                server: server, bundle: bundle(), members: ids.map { BotTemplate(id: $0, nameEn: $0, nameRu: $0) },
                runtime: .claude, model: nil, languageCode: "en", texts: texts)
            server.creations.setTeam(made, for: AgentCreationStore.bundleKey("b"))
            creation = made
        }
        #expect(weakServer == nil, "ServerModel -> creations -> TeamCreation -> server was a cycle")
        #expect(creation != nil)
    }

    @Test func aCreationWhoseServerIsGoneMakesNothingAndSaysSo() async {
        var creation: TeamCreation?
        do {
            let server = FakeServer()
            creation = team(server)
        }
        #expect(await run(creation!, Folders()) == false)
        #expect(creation?.failure == "nothing")
    }

    @Test func disconnectingTheServerClearsWhatItKept() async {
        let (server, _) = DemoDaemon.server(id: UUID(), name: "Demo", setup: DemoDaemonSetup())
        let made = TeamCreation(
            server: server, bundle: bundle(), members: [], runtime: .claude, model: nil, languageCode: "en", texts: texts)
        server.creations.setTeam(made, for: AgentCreationStore.bundleKey("b"))
        await server.disconnect()
        #expect(server.creations.team(AgentCreationStore.bundleKey("b")) == nil)
    }

    @Test func thePanelAndTheSheetShareOneKeyPerBundle() {
        #expect(AgentCreationStore.bundleKey("web") == AgentCreationStore.bundleKey("web"))
        #expect(AgentCreationStore.bundleKey("web") != AgentCreationStore.bundleKey("docs"))
    }

    @Test func eachAgentIsReportedAsItsAnswerIsLearnedNotAfterTheAttempt() async {
        let server = FakeServer()
        server.losesBundleAnswer = true
        let creation = team(server)
        var noted: [String] = []
        creation.onAgent = { noted.append($0.id) }
        #expect(await run(creation, Folders()))
        #expect(Set(noted) == Set(server.agents.map(\.id)))
        #expect(noted.count == 3)

        let clean = FakeServer()
        let other = team(clean)
        var seen = 0
        other.onAgent = { _ in seen += 1 }
        _ = await run(other, Folders())
        #expect(seen == 3)
    }
}
