import BanditoKit
import BanditoL10n
import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoUI

/// The workplace part of the new agent draft: which workspace the request names, and when the draft can be sent.
@Suite struct WorkplaceDraftTests {
    /// A draft that passes everything except the workplace.
    private func filled() -> NewAgentDraft {
        var draft = NewAgentDraft()
        draft.name = "Scout"
        draft.cwd = "/Users/me/projects/site"
        return draft
    }

    @Test func sharedServerIsTheDefaultAndNamesNoWorkspace() {
        let draft = filled()
        #expect(draft.workplace == .shared)
        #expect(draft.canCreate)
        #expect(draft.makeNewAgent().workspaceId == nil, "no key on the wire: the daemon uses shared")
    }

    @Test func existingContainerIsNamedInTheRequest() {
        var draft = filled()
        draft.workplace = .existing("0190a1")
        #expect(draft.canCreate)
        #expect(draft.makeNewAgent().workspaceId == "0190a1")
        #expect(draft.makeNewAgent(workspaceID: "ignored").workspaceId == "0190a1", "an existing choice names itself")
    }

    @Test func newContainerNeedsAValidFormBeforeTheAgentCanBeMade() {
        var draft = filled()
        draft.workplace = .new
        #expect(draft.canCreate == false, "a new container needs a name")

        draft.newWorkplace.name = "   "
        #expect(draft.canCreate == false, "a blank name is no name")

        draft.newWorkplace.name = String(repeating: "x", count: 65)
        #expect(draft.canCreate == false, "names are at most 64 characters")

        draft.newWorkplace.name = "  Watch  "
        #expect(draft.canCreate)
        #expect(draft.newWorkplace.trimmedName == "Watch")
    }

    @Test func newContainerLimitsMustBeInTheDaemonRanges() {
        var draft = filled()
        draft.workplace = .new
        draft.newWorkplace.name = "Box"
        draft.newWorkplace.limits = WorkspaceLimits(cpus: 0.05, memoryMb: 1024)
        #expect(draft.canCreate == false)
        draft.newWorkplace.limits = WorkspaceLimits(cpus: nil, memoryMb: nil)
        #expect(draft.canCreate, "no limit is allowed")
    }

    @Test func newContainerTakesTheIdOfTheContainerMadeFirst() {
        var draft = filled()
        draft.workplace = .new
        draft.newWorkplace.name = "Box"
        #expect(draft.makeNewAgent().workspaceId == nil, "until the container exists there is nothing to name")
        #expect(draft.makeNewAgent(workspaceID: "0190b2").workspaceId == "0190b2")
    }

    @Test func newContainerRequestUsesDefaultsAndInternet() {
        var draft = NewWorkplaceDraft()
        draft.name = "  Box "
        let request = draft.makeNewWorkspace()
        #expect(request.name == "Box")
        #expect(request.kind == .container)
        #expect(request.network == .internet, "the CLIs need the network to reach their models")
        #expect(request.cpus == WorkspaceLimits.defaults.cpus)
        #expect(request.memoryMb == WorkspaceLimits.defaults.memoryMb)
        #expect(request.mounts.isEmpty)
    }

    @Test func offlineNetworkAndLimitsGoIntoTheRequest() {
        var draft = NewWorkplaceDraft()
        draft.name = "Quiet"
        draft.network = .offline
        draft.limits = WorkspaceLimits(cpus: 4, memoryMb: nil)
        let request = draft.makeNewWorkspace()
        #expect(request.network == .offline)
        #expect(request.cpus == 4)
        #expect(request.memoryMb == nil)
    }

    @Test func limitsTextReadsLikeTheForm() {
        var draft = NewWorkplaceDraft()
        #expect(draft.limitsText == "2 CPU, 2048 MB")
        draft.limits = WorkspaceLimits(cpus: 0.5, memoryMb: nil)
        #expect(draft.limitsText == "0.5 CPU, \(L10n.Workspace.Create.unlimited)")
    }

    @Test func switchingBackToSharedDropsTheContainerChoice() {
        var draft = filled()
        draft.workplace = .new
        draft.newWorkplace.name = "Box"
        draft.workplace = .shared
        #expect(draft.makeNewAgent(workspaceID: "0190b2").workspaceId == nil)
        #expect(draft.workplace.mode == .shared)
        draft.workplace = .existing("0190a1")
        #expect(draft.workplace.mode == .separate)
    }
}

/// Failures of a workplace turn into one sentence each; a folder with Bandito's own data gets its own.
@Suite struct WorkspaceTextTests {
    private func failure(_ reason: String, message: String = "daemon text") -> RPCError {
        RPCError(code: RPCError.workspaceError, message: message, data: .object(["reason": .string(reason)]))
    }

    @Test func eachReasonHasItsOwnSentence() {
        #expect(WorkspaceText.failure(failure("docker_unavailable")) == L10n.Workspace.Error.dockerUnavailable)
        #expect(WorkspaceText.failure(failure("not_found")) == L10n.Workspace.Error.notFound)
        #expect(WorkspaceText.failure(failure("builtin")) == L10n.Workspace.Error.builtin)
        #expect(WorkspaceText.failure(failure("not_empty")) == L10n.Workspace.Error.notEmpty)
        #expect(WorkspaceText.failure(failure("docker", message: "boom")) == L10n.Workspace.Error.docker(message: "boom"))
        #expect(WorkspaceText.failure(failure("invalid", message: "cpus must be between 0.1 and 64"))
            == L10n.Workspace.Error.invalid(message: "cpus must be between 0.1 and 64"))
    }

    @Test func aFolderWithBanditoDataGetsItsOwnSentence() {
        let message = "/Users/me/.bandito contains Bandito's own data and cannot be mounted"
        #expect(WorkspaceText.failure(failure("invalid", message: message)) == L10n.Workspace.Error.banditoData)
    }

    @Test func unknownReasonKeepsTheDaemonText() {
        #expect(WorkspaceText.failure(failure("from_the_future", message: "new thing")) == L10n.Workspace.Error.other(message: "new thing"))
    }

    @Test func otherErrorsKeepTheirOwnText() {
        let timeout = RPCError(code: RPCError.timedOut, message: "no answer")
        #expect(WorkspaceText.failure(timeout) == nil)
        // A timed-out call is a server that does not answer: the mapper's sentence, never the raw description.
        #expect(WorkspaceText.message(for: timeout).text == L10n.Failure.noAnswer)
        #expect(WorkspaceText.message(for: failure("not_found")).text == L10n.Workspace.Error.notFound)
    }
}
