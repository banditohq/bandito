import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Choosing a workplace in the Screen, Browser, Terminals and Files modes: the rules, the kept choice, the screen cards
/// and the folders a container sees.
@MainActor
@Suite final class WorkspaceChoiceTests {
    /// One server for the whole test: the kept choice is per server.
    private let server = ServerModel(config: ServerConfig(name: "s", endpoint: .defaultLocal))
    private let shared = Workspace(id: Workspace.sharedID, name: "Shared", kind: .shared)

    private func box(
        _ id: String, name: String = "Тест", running: Bool = true, mounts: [WorkspaceMount] = []
    ) -> Workspace {
        Workspace(
            id: id, name: name, kind: .container, mounts: mounts,
            status: WorkspaceStatus(running: running, containerId: running ? "c-\(id)" : nil))
    }

    private func agent(_ id: String, name: String, cwd: String, home: String? = nil, in workspace: String) -> Agent {
        let agent = Agent(id: id, name: name, runtime: .claude, cwd: cwd, homeDir: home, workspaceId: workspace)
        return agent
    }

    /// The suites this test made; they are removed when the test ends, so nothing stays in the preferences folder.
    nonisolated(unsafe) private var suites: [String] = []

    deinit {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    private func defaults() -> UserDefaults {
        let suite = "WorkspaceChoiceTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func selection(
        mode: String = "screen", workspaces: [Workspace], loaded: Bool = true, defaults: UserDefaults
    ) -> WorkspaceSelection {
        let directory = WorkspaceDirectory(server: server, workspaces: workspaces, loaded: loaded)
        return WorkspaceSelection(mode: mode, directory: directory, defaults: defaults)
    }

    // MARK: The workplace to show

    @Test func beforeTheListArrivesTheSavedChoiceStands() {
        #expect(WorkspacePickerLogic.effective(saved: "box-1", workspaces: [], loaded: false) == "box-1")
        #expect(WorkspacePickerLogic.effective(saved: nil, workspaces: [], loaded: false) == Workspace.sharedID)
    }

    @Test func onceTheListIsThereAGoneContainerFallsBackToShared() {
        let list = [shared, box("box-1")]
        #expect(WorkspacePickerLogic.effective(saved: "box-1", workspaces: list, loaded: true) == "box-1")
        #expect(WorkspacePickerLogic.effective(saved: "gone", workspaces: list, loaded: true) == Workspace.sharedID)
        #expect(WorkspacePickerLogic.isGone(saved: "gone", workspaces: list, loaded: true))
        #expect(!WorkspacePickerLogic.isGone(saved: "box-1", workspaces: list, loaded: true))
        #expect(!WorkspacePickerLogic.isGone(saved: "gone", workspaces: list, loaded: false))
        #expect(!WorkspacePickerLogic.isGone(saved: nil, workspaces: list, loaded: true))
    }

    @Test func aStoppedContainerStaysChosenAndOffersStart() {
        let stopped = box("box-1", running: false)
        #expect(WorkspacePickerLogic.effective(saved: "box-1", workspaces: [shared, stopped], loaded: true) == "box-1")
        #expect(WorkspacePickerLogic.needsStartBeforeTerminal(stopped))
        #expect(!WorkspacePickerLogic.needsStartBeforeTerminal(box("box-2")))
        #expect(!WorkspacePickerLogic.needsStartBeforeTerminal(shared))
        #expect(!WorkspacePickerLogic.needsStartBeforeTerminal(nil))
    }

    @Test func theSharedWorkplaceIsAskedForWithNoParameter() {
        #expect(WorkspacePickerLogic.rpcParameter(Workspace.sharedID) == nil)
        #expect(WorkspacePickerLogic.rpcParameter("box-1") == "box-1")
    }

    @Test func pickerIsOfferedOnlyWithMoreThanOneWorkplace() {
        #expect(!WorkspacePickerLogic.offersChoice([shared]))
        #expect(!WorkspacePickerLogic.offersChoice([]))
        #expect(WorkspacePickerLogic.offersChoice([shared, box("box-1")]))
    }

    @Test func rowsMarkTheChosenAndBusyOnes() {
        let rows = WorkspacePickerLogic.rows(
            workspaces: [shared, box("box-1", running: false)], selectedID: "box-1", busyID: "box-1")
        #expect(rows.count == 2)
        #expect(!rows[0].selected && !rows[0].isContainer && rows[0].live == .serverRunning)
        #expect(rows[1].selected && rows[1].busy && rows[1].canStart && rows[1].live == .containerStopped)
        // A poll that changes nothing the row shows gives an equal row, so nothing redraws.
        let again = WorkspacePickerLogic.rows(
            workspaces: [shared, box("box-1", running: false)], selectedID: "box-1", busyID: "box-1")
        #expect(rows == again)
    }

    @Test func labelsNameOnlyContainers() {
        let list = [shared, box("box-1", name: "Тест")]
        #expect(WorkspacePickerLogic.label(workspaceID: Workspace.sharedID, workspaces: list) == nil)
        #expect(WorkspacePickerLogic.label(workspaceID: "box-1", workspaces: list) == "Тест")
        #expect(WorkspacePickerLogic.label(workspaceID: "gone", workspaces: list) == nil)
    }

    // MARK: The kept choice

    @Test func choosingIsKeptPerModeAndServer() {
        let store = defaults()
        let list = [shared, box("box-1")]
        let screen = selection(mode: "screen", workspaces: list, defaults: store)
        #expect(screen.selectedID == Workspace.sharedID)
        screen.select("box-1")
        #expect(screen.selectedID == "box-1")
        #expect(store.string(forKey: screen.key) == "box-1")

        // A new selection (the app started again) reads it back; another mode on the same server is its own.
        #expect(selection(mode: "screen", workspaces: list, defaults: store).selectedID == "box-1")
        #expect(selection(mode: "browser", workspaces: list, defaults: store).selectedID == Workspace.sharedID)
    }

    @Test func aDeletedContainerFallsBackToSharedAndIsForgotten() {
        let store = defaults()
        let chosen = selection(workspaces: [shared, box("box-1")], defaults: store)
        chosen.select("box-1")
        // The container is deleted: the list no longer holds it.
        let after = WorkspaceDirectory(server: server, workspaces: [shared], loaded: true)
        let reread = WorkspaceSelection(mode: chosen.mode, directory: after, defaults: store)
        #expect(reread.selectedID == Workspace.sharedID)
        reread.reconcile()
        #expect(store.string(forKey: reread.key) == nil)
    }

    @Test func aChoiceIsNotDroppedWhileTheListIsStillLoading() {
        let store = defaults()
        let first = selection(workspaces: [shared, box("box-1")], defaults: store)
        first.select("box-1")
        let loading = selection(workspaces: [], loaded: false, defaults: store)
        #expect(loading.selectedID == "box-1")
        loading.reconcile()
        #expect(store.string(forKey: loading.key) == "box-1")
    }

    @Test func choosingTheSameWorkplaceAgainWritesNothing() {
        let store = defaults()
        let chosen = selection(workspaces: [shared, box("box-1")], defaults: store)
        chosen.select(Workspace.sharedID)
        #expect(store.string(forKey: chosen.key) == nil)
    }

    // MARK: Screen cards

    @Test func aScreenCardFollowsTheAnswerOfTheDaemon() {
        let asleep = ScreenStatus(running: false)
        let running = ScreenStatus(running: true, vncPort: 5900, vncPassword: "abcdefgh")
        #expect(ScreenCardRules.state(status: asleep, refusal: nil, workspaceID: "box-1", previous: .unknown) == .asleep)
        #expect(ScreenCardRules.state(status: running, refusal: nil, workspaceID: "box-1", previous: .asleep) == .running)
    }

    @Test func anOldDaemonRefusingTheIdMakesTheCardUnavailable() {
        let refusal = RPCError(code: RPCError.invalidParams, message: "workspace must be 1 to 32 letters")
        #expect(
            ScreenCardRules.state(status: nil, refusal: refusal, workspaceID: "019b-long-id", previous: .unknown)
                == .unavailable)
        // The shared workplace is never "unavailable" for this reason.
        #expect(
            ScreenCardRules.state(status: nil, refusal: refusal, workspaceID: Workspace.sharedID, previous: .asleep)
                == .asleep)
    }

    @Test func aDroppedConnectionLeavesTheCardAsItWas() {
        let dropped = RPCError(code: RPCError.disconnected, message: "closed")
        #expect(ScreenCardRules.state(status: nil, refusal: dropped, workspaceID: "box-1", previous: .running) == .running)
    }

    @Test func screenPhaseSaysUnavailableBeforeAnythingElse() {
        let facts = ScreenStartRules.Facts(
            supported: true, startInFlight: false, running: false, hasFrame: false, frameTimedOut: false, error: nil,
            workplaceUnavailable: true)
        #expect(ScreenStartRules.phase(facts) == .workplaceUnavailable)
        var old = facts
        old.supported = false
        #expect(ScreenStartRules.phase(old) == .needsUpdate)
    }

    @Test func cardsAreEqualWhenNothingTheyShowChanged() {
        let list = [shared, box("box-1")]
        let one = ScreenCardData.make(workspaces: list, states: ["box-1": .running], selectedID: "box-1")
        let two = ScreenCardData.make(workspaces: list, states: ["box-1": .running], selectedID: "box-1")
        #expect(one == two)
        let other = ScreenCardData.make(workspaces: list, states: ["box-1": .asleep], selectedID: "box-1")
        #expect(one != other)
    }

    // MARK: Folders of a container

    @Test func aContainerSeesItsAgentsFoldersAndTheAddedOnes() {
        let box1 = box("box-1", mounts: [WorkspaceMount(host: "/data/shared", target: "/data/shared", readOnly: true)])
        let agents = [
            agent("a1", name: "Zed", cwd: "/work/zed", home: "/agents/zed", in: "box-1"),
            agent("a2", name: "Ann", cwd: "/work/ann", in: "box-1"),
            agent("a3", name: "Out", cwd: "/work/out", in: Workspace.sharedID),
        ]
        let folders = WorkspaceFolders.folders(of: box1, in: [shared, box1], agents: agents)
        #expect(folders.map(\.path) == ["/work/ann", "/work/zed", "/agents/zed", "/data/shared"])
        #expect(folders[0].origin == .agent(name: "Ann"))
        let added = folders[3]
        #expect(added.origin == .added && added.readOnly && added.shared)
        // The agent folders are the container's own: not shared with another one.
        #expect(!folders[0].shared && !folders[1].shared)
    }

    @Test func aFolderTwoContainersSeeIsMarkedShared() {
        let one = box("box-1", mounts: [WorkspaceMount(host: "/data/x", target: "/data/x")])
        let two = box("box-2", name: "Второе", mounts: [WorkspaceMount(host: "/data/x", target: "/data/x")])
        let agents = [agent("a1", name: "Ann", cwd: "/data/x", in: "box-1")]
        let folders = WorkspaceFolders.folders(of: one, in: [shared, one, two], agents: agents)
        // The path is once, named by the agent that works there, and marked as seen by another container too.
        #expect(folders.count == 1)
        #expect(folders[0].origin == .agent(name: "Ann"))
        #expect(folders[0].shared)
    }

    @Test func anAgentFolderThatWasAlsoAddedIsShared() {
        let one = box("box-1", mounts: [WorkspaceMount(host: "/work/ann", target: "/work/ann")])
        let agents = [agent("a1", name: "Ann", cwd: "/work/ann", in: "box-1")]
        let folders = WorkspaceFolders.folders(of: one, in: [shared, one], agents: agents)
        #expect(folders.count == 1 && folders[0].origin == .agent(name: "Ann") && folders[0].shared)
    }

    @Test func theSharedWorkplaceHasNoFolderGroup() {
        #expect(WorkspaceFolders.folders(of: shared, in: [shared], agents: []).isEmpty)
    }

    // MARK: Terminals know their workplace

    @Test func aTerminalFromAnOlderDaemonRunsOnTheSharedServer() throws {
        let json = """
            {"id":"t1","title":"zsh","cwd":"/","command":["/bin/zsh"],"pid":1,"cols":80,"rows":24,
             "created_at":1,"state":{"state":"running"},"offset":0}
            """
        let old = try RPCClient.decoder.decode(TermInfo.self, from: Data(json.utf8))
        #expect(old.workspace == Workspace.sharedID)
        let withWorkspace = json.replacingOccurrences(of: "\"offset\":0", with: "\"offset\":0,\"workspace\":\"box-1\"")
        let new = try RPCClient.decoder.decode(TermInfo.self, from: Data(withWorkspace.utf8))
        #expect(new.workspace == "box-1")
        #expect(new.state == .running)
    }
}
