#if os(macOS) && DEBUG
import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The crew step's model against the demo daemon that lives in memory: the real `ServerModel`, the real RPC calls,
/// no network. A team that fails in the middle is made again without doubling anything.
@MainActor
@Suite(.serialized) struct CrewModelDemoTests {
    private func ready() async -> (OnboardingWorld, CrewModel) {
        let world = OnboardingWorld(step: .team)
        await world.prepare(readServerSteps: true)
        let crew = world.session!.crew
        return (world, crew)
    }

    @Test func aTeamThatFailedInTheMiddleIsFinishedWithoutDoublingAnything() async throws {
        let (world, crew) = await ready()
        defer { Task { await world.stop() } }
        #expect(crew.choice == .team("web-project"))
        #expect(crew.canCreate)

        // The tester cannot be made the first time.
        await world.transport.failBundleEntry(templateID: "qa-tester", failing: true)
        let first = await crew.create()
        #expect(first == nil)
        #expect(!crew.isDone)
        #expect(crew.madeAgents.count == 2)
        #expect(crew.failure?.canRetry == true)
        try await world.server.readAgentsNow()
        #expect(world.server.agents.count == 2)

        // The retry asks for the one that is missing, in the same folder, and it works.
        await world.transport.failBundleEntry(templateID: "qa-tester", failing: false)
        let folderBefore = crew.teamCreation?.folder
        let second = await crew.create()
        #expect(second != nil)
        #expect(crew.isDone)
        try await world.server.readAgentsNow()
        #expect(world.server.agents.count == 3)
        #expect(Set(world.server.agents.map(\.name)).count == 3)
        #expect(crew.teamCreation?.folder == folderBefore)
        #expect(Set(world.server.agents.map(\.cwd)).count == 1)
        // A third tap does nothing.
        _ = await crew.create()
        try await world.server.readAgentsNow()
        #expect(world.server.agents.count == 3)
    }

    @Test func oneAgentIsMadeOnceInItsOwnFolder() async throws {
        let (world, crew) = await ready()
        defer { Task { await world.stop() } }
        crew.select(.single)
        crew.setName("Forge")
        // The default folder is checked against the folders that exist first.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(crew.canCreate)
        let agent = await crew.create()
        #expect(agent?.name == "Forge")
        #expect(crew.isDone)
        #expect(crew.firstAgent?.id == agent?.id)
        _ = await crew.create()
        try await world.server.readAgentsNow()
        #expect(world.server.agents.count == 1)
    }

    @Test func theRuntimeChoiceFollowsWhatIsSignedIn() async {
        let (world, crew) = await ready()
        defer { Task { await world.stop() } }
        // The demo has Claude Code and Codex signed in; Grok cannot be checked and waits for the person's "Done".
        #expect(crew.available == [.claude, .codex])
        #expect(crew.runtime == .claude)
        crew.chooseRuntime(.grok)
        #expect(crew.runtime == .claude)
        crew.chooseRuntime(.codex)
        #expect(crew.runtime == .codex)
    }

    @Test func aStepAfterARelaunchShowsTheCrewThatWasMadeAndMakesNothing() async throws {
        let (world, crew) = await ready()
        defer { Task { await world.stop() } }
        _ = await crew.create()
        let made = crew.firstAgent
        #expect(made != nil)
        // A new model (a new launch) is told the agent the flow remembers: the crew is shown as made.
        let again = CrewModel(server: world.server, subscriptions: world.session!.subscriptions)
        again.adopt(try #require(made))
        #expect(again.isDone)
        #expect(again.madeAgents.map(\.id) == [made!.id])
    }
}
#endif
