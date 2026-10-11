import Foundation
import Testing

@testable import BanditoUI

/// The agent's own folder in the new agent sheet: its name, the agents folder it goes into, and the free name it gets.
@Suite struct NewAgentFolderRulesTests {
    // MARK: Folder name

    @Test func cyrillicAndSpacesAreKept() {
        #expect(NewAgentFolderRules.folderName(for: "Агент 1") == "Агент 1")
        #expect(NewAgentFolderRules.folderName(for: "Ёж Щи") == "Ёж Щи")
    }

    @Test func emptyDotAndDotDotBecomeAgent() {
        #expect(NewAgentFolderRules.folderName(for: "") == "agent")
        #expect(NewAgentFolderRules.folderName(for: "   ") == "agent")
        #expect(NewAgentFolderRules.folderName(for: ".") == "agent")
        #expect(NewAgentFolderRules.folderName(for: " .. ") == "agent")
    }

    @Test func forbiddenCharactersBecomeDashes() {
        #expect(NewAgentFolderRules.folderName(for: "a/b\\c:d*e?f\"g<h>i|j") == "a-b-c-d-e-f-g-h-i-j")
    }

    @Test func controlCharactersBecomeDashes() {
        #expect(NewAgentFolderRules.folderName(for: "tab\there\nnew") == "tab-here-new")
    }

    @Test func outerSpacesAreTrimmed() {
        #expect(NewAgentFolderRules.folderName(for: "  Forge  ") == "Forge")
    }

    @Test func longNameIsCutToSixtyFourCharacters() {
        let name = NewAgentFolderRules.folderName(for: String(repeating: "я", count: 100))
        #expect(name.count == 64)
    }

    @Test func cutDoesNotLeaveATrailingSpace() {
        let name = NewAgentFolderRules.folderName(for: String(repeating: "a", count: 63) + " bcd")
        #expect(name == String(repeating: "a", count: 63))
    }

    // MARK: Free name

    @Test func firstCandidateIsTheNameThenNumbers() {
        #expect(NewAgentFolderRules.candidate(base: "Forge", attempt: 1) == "Forge")
        #expect(NewAgentFolderRules.candidate(base: "Forge", attempt: 2) == "Forge 2")
        #expect(NewAgentFolderRules.candidate(base: "Forge", attempt: 3) == "Forge 3")
    }

    @Test func numberedCandidateStaysWithinTheLimit() {
        let base = String(repeating: "a", count: 64)
        let candidate = NewAgentFolderRules.candidate(base: base, attempt: 2)
        #expect(candidate.count <= 64)
        #expect(candidate.hasSuffix(" 2"))
    }

    // MARK: Paths

    @Test func folderPathJoinsRootAndName() {
        #expect(NewAgentFolderRules.folderPath(root: "/home/me/Bandito", name: "Forge") == "/home/me/Bandito/Forge")
        #expect(NewAgentFolderRules.folderPath(root: "/home/me/Bandito/", name: "Forge") == "/home/me/Bandito/Forge")
        #expect(NewAgentFolderRules.folderPath(root: "/", name: "Forge") == "/Forge")
    }

    @Test func parentOfAPath() {
        #expect(NewAgentFolderRules.parent(of: "/home/me/billing") == "/home/me")
        #expect(NewAgentFolderRules.parent(of: "/home/me/billing/") == "/home/me")
        #expect(NewAgentFolderRules.parent(of: "/billing") == "/")
        #expect(NewAgentFolderRules.parent(of: "/") == nil)
        #expect(NewAgentFolderRules.parent(of: "") == nil)
    }

    @Test func ownFoldersOfAgentsAreNotProjectFolders() {
        #expect(NewAgentFolderRules.projectFolder(cwd: "", homeDir: "/home/me/agents/x") == nil)
        #expect(NewAgentFolderRules.projectFolder(cwd: "/home/me/agents/x", homeDir: "/home/me/agents/x") == nil)
        #expect(NewAgentFolderRules.projectFolder(cwd: "/srv/a/billing", homeDir: nil) == "/srv/a/billing")
    }

    // MARK: Default agents folder

    @Test func withNoAgentsTheAgentsFolderIsBanditoInTheHome() {
        #expect(NewAgentFolderRules.defaultRoot(saved: nil, projectFolders: [], home: "/home/me") == "/home/me/Bandito")
        #expect(NewAgentFolderRules.defaultRoot(saved: nil, projectFolders: [], home: "/") == "/Bandito")
    }

    @Test func noHomeAndNoAnswerMeansNoDefault() {
        #expect(NewAgentFolderRules.defaultRoot(saved: nil, projectFolders: [], home: nil) == nil)
    }

    @Test func twoAgentsInOneParentShareTheParent() {
        let folders = ["/srv/a/billing", "/srv/a/site"]
        #expect(NewAgentFolderRules.defaultRoot(saved: nil, projectFolders: folders, home: "/home/me") == "/srv/a")
    }

    @Test func oneAgentIsNotEnoughForItsParent() {
        let root = NewAgentFolderRules.defaultRoot(saved: nil, projectFolders: ["/srv/a/billing"], home: "/home/me")
        #expect(root == "/home/me/Bandito")
    }

    @Test func agentsInDifferentParentsFallBackToTheHome() {
        let folders = ["/srv/a/x", "/srv/b/y"]
        #expect(NewAgentFolderRules.defaultRoot(saved: nil, projectFolders: folders, home: "/home/me") == "/home/me/Bandito")
    }

    @Test func theParentWithMostAgentsWins() {
        let folders = ["/srv/a/x", "/srv/b/y", "/srv/b/z"]
        #expect(NewAgentFolderRules.defaultRoot(saved: nil, projectFolders: folders, home: "/home/me") == "/srv/b")
    }

    @Test func aTieGoesToTheParentListedFirst() {
        let folders = ["/srv/a/x", "/srv/b/y", "/srv/a/z", "/srv/b/w"]
        #expect(NewAgentFolderRules.defaultRoot(saved: nil, projectFolders: folders, home: "/home/me") == "/srv/a")
    }

    @Test func aSavedAgentsFolderWinsOverTheAgents() {
        let folders = ["/srv/a/x", "/srv/a/y"]
        #expect(NewAgentFolderRules.defaultRoot(saved: "/data/agents", projectFolders: folders, home: "/home/me") == "/data/agents")
    }

    @Test func aBlankSavedFolderIsIgnored() {
        #expect(NewAgentFolderRules.defaultRoot(saved: "", projectFolders: [], home: "/home/me") == "/home/me/Bandito")
    }

    @Test func theSavedAgentsFolderIsKeptPerServer() {
        let suite = "NewAgentFolderRulesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AgentsRootStore.load(serverID: "server-1", defaults: defaults) == nil)
        AgentsRootStore.save("/data/agents", serverID: "server-1", defaults: defaults)
        #expect(AgentsRootStore.load(serverID: "server-1", defaults: defaults) == "/data/agents")
        #expect(AgentsRootStore.load(serverID: "server-2", defaults: defaults) == nil)
        #expect(defaults.string(forKey: "agents.root.server-1") == "/data/agents")
    }
}

/// The draft's folder mode: a new folder in the agents folder is the default, and it needs that folder to create.
@Suite struct NewAgentDraftFolderModeTests {
    @Test func newFolderIsTheDefaultMode() {
        #expect(NewAgentDraft().folderMode == .newFolder)
    }

    @Test func newFolderNeedsTheAgentsFolder() {
        var draft = NewAgentDraft()
        draft.name = "Forge"
        draft.cwd = "/home/me/billing"
        #expect(!draft.canCreate, "the picked folder is not used in the new folder mode")
        #expect(draft.createBlocker(status: nil) == .folder)

        draft.agentsRoot = "/home/me/Bandito"
        #expect(draft.canCreate)
        #expect(draft.createBlocker(status: nil) == nil)
    }

    @Test func existingFolderKeepsItsRule() {
        var draft = NewAgentDraft()
        draft.folderMode = .existing
        #expect(!draft.canCreate)
        draft.cwd = "/home/me/billing"
        #expect(draft.canCreate)
        #expect(draft.createBlocker(status: nil) == nil)
    }
}
