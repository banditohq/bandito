import Foundation
import BanditoL10n
import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct NewAgentDraftTests {
    @Test func changingRuntimeLowersEffortToWhatItOffers() {
        var draft = NewAgentDraft()
        draft.effort = .max
        draft.setRuntime(.codex)
        #expect(draft.effort == .xhigh)
        draft.setRuntime(.grok)
        #expect(draft.effort == .high)
        draft.setRuntime(.claude)
        #expect(draft.effort == .high)
    }

    @Test func templateFillsRuntimeEffortRoleAndInstructions() {
        var draft = NewAgentDraft()
        draft.name = "Forge"
        AgentTemplate.reviewer.apply(to: &draft)
        #expect(draft.runtime == .codex)
        #expect(draft.effort == .high)
        #expect(draft.role == AgentTemplate.reviewer.title)
        #expect(draft.instructions == AgentTemplate.reviewer.instructions)
        #expect(!draft.instructions.isEmpty)
        #expect(draft.name == "Forge")
    }

    @Test func researcherTemplateUsesGrokAtHighEffort() {
        var draft = NewAgentDraft()
        AgentTemplate.researcher.apply(to: &draft)
        #expect(draft.runtime == .grok)
        #expect(draft.effort == .high)
    }

    @Test func scratchTemplateClearsRoleAndInstructions() {
        var draft = NewAgentDraft()
        AgentTemplate.builder.apply(to: &draft)
        AgentTemplate.scratch.apply(to: &draft)
        #expect(draft.role.isEmpty)
        #expect(draft.instructions.isEmpty)
        #expect(draft.runtime == .claude)
    }

    @Test func nameIsOptional() {
        var draft = NewAgentDraft()
        draft.cwd = "/home/me/billing"
        #expect(draft.canCreate)
        draft.name = "   "
        #expect(draft.canCreate)
    }

    @Test func createNeedsAProjectFolder() {
        var draft = NewAgentDraft()
        draft.name = "Forge"
        #expect(!draft.canCreate)
        draft.cwd = "   "
        #expect(!draft.canCreate)
        draft.cwd = "/home/me/billing"
        #expect(draft.canCreate)
    }

    @Test func typedNameWinsOverTheDefault() {
        var draft = NewAgentDraft()
        draft.name = "  Forge "
        draft.role = "reviewer"
        #expect(draft.resolvedName(existing: []) == "Forge")
    }

    @Test func emptyNameTakesTheRoleWhenItIsFree() {
        var draft = NewAgentDraft()
        draft.role = "  reviewer "
        #expect(draft.resolvedName(existing: ["Forge"]) == "reviewer")
        #expect(draft.resolvedName(existing: ["Reviewer"]) == NewAgentDraft.defaultName(1))
    }

    @Test func emptyNameWithoutRoleIsNumbered() {
        let draft = NewAgentDraft()
        #expect(draft.resolvedName(existing: []) == NewAgentDraft.defaultName(1))
    }

    @Test func numberingSkipsTakenNames() {
        let draft = NewAgentDraft()
        let existing = [NewAgentDraft.defaultName(1), NewAgentDraft.defaultName(2).uppercased(), "Forge"]
        #expect(draft.resolvedName(existing: existing) == NewAgentDraft.defaultName(3))
    }

    @Test func roleWithCharactersTheNameRuleRefusesIsNotUsed() {
        var draft = NewAgentDraft()
        draft.role = "e.g. reviewer!"
        #expect(draft.resolvedName(existing: []) == NewAgentDraft.defaultName(1))
    }

    @Test func makeNewAgentUsesTheResolvedName() {
        var draft = NewAgentDraft()
        draft.cwd = "/home/me/billing"
        #expect(draft.makeNewAgent(existingNames: [NewAgentDraft.defaultName(1)]).name == NewAgentDraft.defaultName(2))
        draft.name = "Forge"
        #expect(draft.makeNewAgent(existingNames: []).name == "Forge")
    }

    @Test func runtimeMissingBlocksCreation() {
        var draft = NewAgentDraft()
        draft.cwd = "/home/me/billing"
        draft.runtime = .codex
        let missing = RuntimeStatus(kind: .codex, installed: false, version: nil, loggedIn: nil, detail: nil)
        #expect(draft.createBlocker(status: missing) == .runtimeMissing(.codex))
    }

    @Test func notSignedInBlocksCreationWithTheLoginCommand() {
        var draft = NewAgentDraft()
        draft.cwd = "/home/me/billing"
        draft.runtime = .codex
        let out = RuntimeStatus(kind: .codex, installed: true, version: "0.46.0", loggedIn: false, detail: nil)
        #expect(draft.createBlocker(status: out) == .runtimeLogin(.codex, command: "codex login"))
    }

    @Test func runtimeIsNotBlockingWhileItIsUnknownOrReady() {
        var draft = NewAgentDraft()
        draft.cwd = "/home/me/billing"
        #expect(draft.createBlocker(status: nil) == nil)
        let ready = RuntimeStatus(kind: .claude, installed: true, version: "2.0.5", loggedIn: nil, detail: nil)
        #expect(draft.createBlocker(status: ready) == nil)
    }

    @Test func missingFolderBlocksCreation() {
        var draft = NewAgentDraft()
        let ready = RuntimeStatus(kind: .claude, installed: true, version: nil, loggedIn: true, detail: nil)
        #expect(draft.createBlocker(status: ready) == .folder)
        draft.cwd = "/home/me/billing"
        #expect(draft.createBlocker(status: ready) == nil)
    }

    @Test func runtimeProblemIsReportedBeforeTheFolder() {
        let draft = NewAgentDraft()
        let missing = RuntimeStatus(kind: .claude, installed: false, version: nil, loggedIn: nil, detail: nil)
        #expect(draft.createBlocker(status: missing) == .runtimeMissing(.claude))
    }

    @Test func invalidNewWorkplaceBlocksCreation() {
        var draft = NewAgentDraft()
        draft.cwd = "/home/me/billing"
        draft.workplace = .new
        #expect(draft.createBlocker(status: nil) == .workplace)
        draft.newWorkplace.name = "Box"
        #expect(draft.createBlocker(status: nil) == nil)
    }

    @Test func makeNewAgentCarriesEveryChoice() {
        var draft = NewAgentDraft()
        draft.name = "  Forge "
        draft.role = "builder"
        draft.runtime = .claude
        draft.model = " opus "
        draft.effort = .high
        draft.instructions = "Small PRs"
        draft.approval = .always
        draft.cwd = "/home/me/billing"

        let agent = draft.makeNewAgent()
        #expect(agent.name == "Forge")
        #expect(agent.role == "builder")
        #expect(agent.runtime == .claude)
        #expect(agent.model == "opus")
        #expect(agent.cwd == "/home/me/billing")
        #expect(agent.approvalMode == .always)
        #expect(agent.effort == .high)
        #expect(agent.memoryMode == .smart)
        #expect(agent.systemPrompt == "Small PRs")
    }

    @Test func emptyModelAndInstructionsAreNil() {
        var draft = NewAgentDraft()
        draft.name = "Forge"
        draft.cwd = "/home/me/billing"
        draft.model = "   "
        draft.instructions = ""
        let agent = draft.makeNewAgent()
        #expect(agent.model == nil)
        #expect(agent.systemPrompt == nil)
    }

    @Test func approvalChoicesMapToModes() {
        #expect(ApprovalChoice.allCases.map(\.mode) == [.risky, .always, .never])
    }

    @Test func modelPresetsAreClaudeAliasesOnly() {
        #expect(NewAgentDraft.modelPresets(for: .claude) == ["opus", "sonnet", "haiku"])
        #expect(NewAgentDraft.modelPresets(for: .codex).isEmpty)
        #expect(NewAgentDraft.modelPresets(for: .grok).isEmpty)
    }
    @Test func fallbackIsSentWhenSet() {
        var draft = NewAgentDraft()
        draft.name = "Forge"
        draft.cwd = "/home/me/billing"
        draft.fallbackRuntime = .codex
        draft.fallbackModel = " gpt-5 "
        let agent = draft.makeNewAgent()
        #expect(agent.fallbackRuntime == .codex)
        #expect(agent.fallbackModel == "gpt-5")
    }

    @Test func noFallbackMeansNil() {
        var draft = NewAgentDraft()
        draft.fallbackModel = "  "
        let agent = draft.makeNewAgent()
        #expect(agent.fallbackRuntime == nil)
        #expect(agent.fallbackModel == nil)
    }

    @Test func fallbackOffersOtherRuntimesOnly() {
        #expect(NewAgentDraft.fallbackOptions(for: .claude) == [.codex, .grok])
        #expect(!NewAgentDraft.fallbackOptions(for: .codex).contains(.codex))
    }

    @Test func switchingPrimaryToTheFallbackClearsTheFallback() {
        var draft = NewAgentDraft()
        draft.runtime = .claude
        draft.fallbackRuntime = .codex
        draft.setRuntime(.codex)
        #expect(draft.fallbackRuntime == nil)
        #expect(draft.fallbackModel.isEmpty)
    }

    @Test func folderIsRequiredUnlessTheServerTakesAnAgentWithoutOne() {
        var draft = NewAgentDraft()
        #expect(draft.canCreate == false)
        #expect(draft.createBlocker(status: nil) == .folder)

        draft.folderOptional = true
        #expect(draft.canCreate)
        #expect(draft.createBlocker(status: nil) == nil)
        #expect(draft.makeNewAgent().cwd == "", "an empty folder is sent as is: the agent gets its own")
    }
}

@Suite struct NewAgentDraftAvatarTests {
    @Test func newAgentCarriesEmojiAndCustomColorButNotThePicture() {
        var draft = NewAgentDraft()
        draft.cwd = "/home/me/billing"
        draft.color = .sky
        draft.customHex = "#FF8800"
        draft.emoji = "🦝"
        draft.face = .wink
        draft.picture = Data([1, 2, 3])
        let avatar = draft.makeNewAgent(existingNames: []).avatar
        #expect(avatar == AvatarSpec(color: "#FF8800", face: "wink", emoji: "🦝"))
    }

    @Test func paletteColorIsSentWhenThereIsNoCustomColor() {
        var draft = NewAgentDraft()
        draft.cwd = "/home/me/billing"
        draft.color = .rose
        #expect(draft.makeNewAgent(existingNames: []).avatar == AvatarSpec(color: "rose", face: "chevronDash"))
    }
}
