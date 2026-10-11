import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Which workplace the Screen and Browser show: the saved choice per server and mode, and what each row says.
@Suite struct WorkspacePickerLogicTests {
    private let serverID = UUID(uuidString: "6F1C2B3A-0000-4000-8000-000000000001")!

    private let shared = Workspace(id: Workspace.sharedID, name: "Общий сервер", kind: .shared)

    private func container(
        _ id: String, running: Bool? = nil, error: String? = nil
    ) -> Workspace {
        let status = running.map { WorkspaceStatus(running: $0, containerId: $0 ? "c-\(id)" : nil, error: error) }
            ?? error.map { WorkspaceStatus(running: false, error: $0) }
        return Workspace(id: id, name: "Тест", kind: .container, status: status)
    }

    // MARK: Storage key

    @Test func keyIsPerModeAndServer() {
        let key = WorkspacePickerLogic.storageKey(mode: "screen", serverID: serverID)
        #expect(key == "workspace.screen.6F1C2B3A-0000-4000-8000-000000000001")
        #expect(WorkspacePickerLogic.storageKey(mode: "browser", serverID: serverID)
            != key)
    }

    // MARK: Which workplace is selected

    @Test func noSavedChoiceMeansShared() {
        #expect(WorkspacePickerLogic.resolve(saved: nil, workspaces: [shared, container("box-1")]) == Workspace.sharedID)
    }

    @Test func savedContainerThatStillExistsStaysSelected() {
        let box = container("box-1", running: true)
        #expect(WorkspacePickerLogic.resolve(saved: "box-1", workspaces: [shared, box]) == "box-1")
    }

    @Test func savedContainerThatWasDeletedFallsBackToShared() {
        #expect(WorkspacePickerLogic.resolve(saved: "gone", workspaces: [shared, container("box-1")]) == Workspace.sharedID)
    }

    @Test func savedChoiceIsKeptWhileTheListIsNotLoadedYet() {
        // Before `workspaces.list` answers the list is empty: the saved id is not yet known to be gone, so it is
        // not dropped. The view shows the loading state meanwhile.
        #expect(WorkspacePickerLogic.resolve(saved: "box-1", workspaces: []) == Workspace.sharedID)
    }

    @Test func stoppedContainerStaysSelectedAndCanBeStarted() {
        let box = container("box-1", running: false)
        #expect(WorkspacePickerLogic.resolve(saved: "box-1", workspaces: [shared, box]) == "box-1")
        #expect(WorkspacePickerLogic.liveState(box) == .containerStopped)
        #expect(WorkspacePickerLogic.canStart(box))
    }

    // MARK: Row state

    @Test func sharedServerIsAlwaysRunning() {
        #expect(WorkspacePickerLogic.liveState(shared) == .serverRunning)
        #expect(!WorkspacePickerLogic.canStart(shared))
    }

    @Test func runningContainerHasNoStartButton() {
        let box = container("box-1", running: true)
        #expect(WorkspacePickerLogic.liveState(box) == .containerRunning)
        #expect(!WorkspacePickerLogic.canStart(box))
    }

    @Test func containerWithoutAnyStatusCountsAsStopped() {
        let box = container("box-1")
        #expect(WorkspacePickerLogic.liveState(box) == .containerStopped)
        #expect(WorkspacePickerLogic.canStart(box))
    }

    @Test func dockerErrorIsUnavailableNotStopped() {
        // When Docker cannot answer, starting would fail the same way: the row names the reason instead.
        let box = container("box-1", error: "docker_unavailable")
        #expect(WorkspacePickerLogic.liveState(box) == .unavailable("docker_unavailable"))
        #expect(!WorkspacePickerLogic.canStart(box))
    }
}
