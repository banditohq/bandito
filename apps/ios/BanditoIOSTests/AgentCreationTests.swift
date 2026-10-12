import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// A server that makes what the creation asks for and records it: the agents it holds are its own list, the clock of
/// the agents is `clockOffset` away from the app's. Flags make it fail the way a real daemon does:
/// - `bundleEntriesWithErrors`: the entry has its agent and an error (a schedule failed after the agent was made);
/// - `bundleFailingTemplates`: the entry has an error and no agent;
/// - `bundleLosesAnswer` / `createAgentLosesAnswer`: the agents are made, but the answer is a timeout;
/// - `createAgentFailures`: the next single-agent requests fail before anything is made.
@MainActor
final class FakeAgentMaker: AgentMaking {
    private(set) var agents: [Agent] = []
    private(set) var folderCalls: [String] = []
    private(set) var bundleRequests: [NewBundle] = []
    private(set) var createAgentCalls = 0
    private(set) var readCount = 0
    var bundleEntriesWithErrors: Set<String> = []
    var bundleFailingTemplates: Set<String> = []
    var bundleLosesAnswer = false
    var createAgentLosesAnswer = false
    var createAgentFailures = 0
    /// Added to the time the agents are created at (the server's clock may be ahead or behind).
    var clockOffset: Int64 = 0

    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) + clockOffset }

    func makeFreeFolder(root: String, base: String) async throws -> String {
        folderCalls.append(base)
        return "\(root)/\(base)"
    }

    func createAgent(_ new: NewAgent) async throws -> Agent {
        createAgentCalls += 1
        if createAgentFailures > 0 {
            createAgentFailures -= 1
            throw RPCError(code: -32000, message: "the daemon refused")
        }
        let agent = Agent(id: "made-\(agents.count + 1)", name: new.name, role: new.role, runtime: new.runtime, cwd: new.cwd, createdAt: now)
        agents.append(agent)
        if createAgentLosesAnswer {
            throw RPCError(code: -32000, message: "timed out")
        }
        return agent
    }

    func createBundle(_ new: NewBundle) async throws -> BundleCreation {
        bundleRequests.append(new)
        var entries: [BundleEntry] = []
        for templateID in new.templates ?? [] {
            if bundleFailingTemplates.contains(templateID) {
                entries.append(BundleEntry(templateId: templateID, agent: nil, error: "the agent could not be made"))
                continue
            }
            let agent = Agent(
                id: "bundle-\(agents.count + 1)", name: templateID, role: "", runtime: .claude, cwd: new.cwd ?? "/",
                createdAt: now, templateId: templateID)
            agents.append(agent)
            let error = bundleEntriesWithErrors.contains(templateID) ? "the schedule could not be made" : nil
            entries.append(BundleEntry(templateId: templateID, agent: agent, error: error))
        }
        if bundleLosesAnswer {
            throw RPCError(code: -32000, message: "timed out")
        }
        return BundleCreation(agents: entries)
    }

    func readAgentsNow() async throws {
        readCount += 1
    }
}

/// The retries of the creation sheets. A part that failed is retried without making again what was made, in the same
/// folder. "Made" is judged by the ids on the server, never by the clock or by the error text.
@MainActor
@Suite struct AgentCreationTests {
    @Test func aRetryOfATeamMakesOnlyTheMissingAgentsInOneFolder() async throws {
        let (demo, members, bundle) = try await webTeam()
        defer { Task { await demo.disconnect() } }
        let second = members[1].id

        let fake = FakeAgentMaker()
        fake.bundleFailingTemplates = [second]
        let team = team(fake, bundle, members)

        let first = await team.create(items: [], enabled: [])
        #expect(!first)
        #expect(team.failure != nil)
        #expect(team.madeTemplateIDs == [members[0].id, members[2].id])

        fake.bundleFailingTemplates = []
        let retry = await team.create(items: [], enabled: [])
        #expect(retry)
        #expect(team.failure == nil)
        // One folder, made by the first attempt; the retry asks only for the agent still missing.
        #expect(fake.folderCalls == ["Web project"])
        #expect(fake.bundleRequests.count == 2)
        #expect(fake.bundleRequests[1].templates == [second])
        #expect(fake.agents.count == 3)
    }

    /// (а) The second agent came with an error about its schedule: the agent exists, so a retry does not make it again.
    @Test func anAgentThatCameWithAnErrorIsNotMadeAgain() async throws {
        let (demo, members, bundle) = try await webTeam()
        defer { Task { await demo.disconnect() } }
        let second = members[1].id

        let fake = FakeAgentMaker()
        fake.bundleEntriesWithErrors = [second]
        fake.bundleFailingTemplates = [members[2].id]
        let team = team(fake, bundle, members)

        let first = await team.create(items: [], enabled: [])
        #expect(!first)
        #expect(team.madeTemplateIDs.contains(second))
        #expect(team.failure != nil)

        fake.bundleFailingTemplates = []
        #expect(await team.create(items: [], enabled: []))
        #expect(fake.bundleRequests[1].templates == [members[2].id])
        #expect(fake.agents.filter { $0.templateId == second }.count == 1)
        #expect(fake.agents.count == 3)
    }

    /// (б) The server's clock is an hour ahead, or behind: a lost answer still makes no duplicate.
    @Test func aLostAnswerMakesNoDuplicateWhateverTheServerClock() async throws {
        for offset: Int64 in [3_600_000, -3_600_000] {
            let (demo, members, bundle) = try await webTeam()
            defer { Task { await demo.disconnect() } }
            let fake = FakeAgentMaker()
            fake.clockOffset = offset
            fake.bundleLosesAnswer = true
            let team = team(fake, bundle, members)

            let first = await team.create(items: [], enabled: [])
            #expect(first, "the lost answer is read from the list (offset \(offset))")
            #expect(team.failure == nil)
            #expect(fake.bundleRequests.count == 1)
            #expect(fake.agents.count == 3)
            #expect(fake.folderCalls == ["Web project"])
        }
    }

    /// (в) The single agent's answer is a timeout, but the agent is on the server: the retry makes no second one and
    /// the sheet can close as a success.
    @Test func aTimeoutOfOneAgentThatWasMadeIsASuccessNotASecondAgent() async {
        let fake = FakeAgentMaker()
        fake.createAgentLosesAnswer = true
        let creation = OneAgentCreation(server: fake, root: "/Users/demo", base: "Ledger")
        let build: (String) -> NewAgent = { folder in
            AgentForms.newAgent(
                name: "Ledger", role: "", runtime: .claude, model: nil, folder: folder, approval: .risky,
                effort: nil, permissions: [])
        }

        let made = await creation.create(build: build)
        #expect(made)
        #expect(creation.failure == nil)
        #expect(creation.createdAgentID == fake.agents.first?.id)

        let again = await creation.create(build: build)
        #expect(again)
        #expect(fake.createAgentCalls == 1)
        #expect(fake.agents.count == 1)
    }

    @Test func aRetryOfOneAgentKeepsItsFolder() async {
        let fake = FakeAgentMaker()
        fake.createAgentFailures = 1
        let creation = OneAgentCreation(server: fake, root: "/Users/demo", base: "Ledger")
        let build: (String) -> NewAgent = { folder in
            AgentForms.newAgent(
                name: "Ledger", role: "", runtime: .claude, model: nil, folder: folder, approval: .risky,
                effort: nil, permissions: [])
        }

        let first = await creation.create(build: build)
        #expect(!first)
        #expect(creation.failure != nil)
        #expect(fake.agents.isEmpty)

        let retry = await creation.create(build: build)
        #expect(retry)
        #expect(fake.folderCalls == ["Ledger"])
        #expect(fake.agents.count == 1)
        #expect(fake.agents.first?.cwd == "/Users/demo/Ledger")
    }

    // MARK: fixtures

    /// The demo server (for the team's real templates) and the web project's bundle and members.
    private func webTeam() async throws -> (ServerModel, [BotTemplate], AgentBundle) {
        let demo = await IOSDemo.start()
        let bundle = try #require(try await demo.agentBundles().first { $0.id == "web-project" })
        let members = try await demo.botTemplates().filter { bundle.templates.contains($0.id) }
        #expect(members.count == 3)
        return (demo, members, bundle)
    }

    private func team(_ fake: FakeAgentMaker, _ bundle: AgentBundle, _ members: [BotTemplate]) -> TeamCreationModel {
        TeamCreationModel(
            server: fake, bundle: bundle, members: members, root: "/Users/demo", runtime: .claude, model: "haiku",
            languageCode: "en")
    }
}
