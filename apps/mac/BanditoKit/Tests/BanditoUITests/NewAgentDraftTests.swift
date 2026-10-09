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

    @Test func createNeedsAName() {
        var draft = NewAgentDraft()
        draft.cwd = "/home/me/billing"
        #expect(!draft.canCreate)
        draft.name = "   "
        #expect(!draft.canCreate)
        draft.name = "  Forge "
        #expect(draft.canCreate)
    }

    @Test func createNeedsAProjectFolder() {
        var draft = NewAgentDraft()
        draft.name = "Forge"
        #expect(!draft.canCreate)
        draft.cwd = "/home/me/billing"
        #expect(draft.canCreate)
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
}
