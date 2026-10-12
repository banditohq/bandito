import Testing

@testable import BanditoKit
@testable import BanditoUI

/// The model a new agent starts on: Haiku for Claude Code when the list has it, nothing for the other runtimes, and
/// never over a choice the person made.
@Suite struct NewAgentModelRulesTests {
    static let withHaikuId = [
        RuntimeModel(id: "opus", name: "Opus 5.5", description: nil, isDefault: true),
        RuntimeModel(id: "sonnet", name: "Sonnet 5.5", description: nil),
        RuntimeModel(id: "haiku", name: "Haiku 5.5", description: nil),
    ]

    static let oldAndNewHaiku = [
        RuntimeModel(id: "claude-opus-5-5", name: "Opus 5.5", description: nil, isDefault: true),
        RuntimeModel(id: "claude-haiku-4-5", name: "Haiku 4.5", description: nil),
        RuntimeModel(id: "claude-haiku-5-5", name: "Haiku 5.5", description: nil),
    ]

    // MARK: Preferred model

    @Test func haikuIdIsPickedWhenTheListHasIt() {
        #expect(NewAgentModelRules.preferredModel(runtime: .claude, models: Self.withHaikuId) == "haiku")
    }

    @Test func withoutHaikuIdTheNewestHaikuByNameIsPicked() {
        #expect(NewAgentModelRules.preferredModel(runtime: .claude, models: Self.oldAndNewHaiku) == "claude-haiku-5-5")
        // The order of the list does not matter: the version does.
        let reversed = Array(Self.oldAndNewHaiku.reversed())
        #expect(NewAgentModelRules.preferredModel(runtime: .claude, models: reversed) == "claude-haiku-5-5")
    }

    @Test func versionsCompareAsNumbersNotAsText() {
        let models = [
            RuntimeModel(id: "claude-haiku-9-9", name: "Haiku 9.9", description: nil),
            RuntimeModel(id: "claude-haiku-10-1", name: "Haiku 10.1", description: nil),
        ]
        #expect(NewAgentModelRules.preferredModel(runtime: .claude, models: models) == "claude-haiku-10-1")
    }

    @Test func noHaikuMeansNoPreference() {
        let models = [RuntimeModel(id: "opus", name: "Opus 5.5", description: nil, isDefault: true)]
        #expect(NewAgentModelRules.preferredModel(runtime: .claude, models: models) == nil)
        #expect(NewAgentModelRules.preferredModel(runtime: .claude, models: []) == nil)
    }

    @Test func otherRuntimesHaveNoPreference() {
        #expect(NewAgentModelRules.preferredModel(runtime: .codex, models: Self.withHaikuId) == nil)
        #expect(NewAgentModelRules.preferredModel(runtime: .grok, models: Self.oldAndNewHaiku) == nil)
        #expect(NewAgentModelRules.preferredModel(runtime: .api, models: Self.withHaikuId) == nil)
    }

    @Test func versionReadsTheNumbersOfAName() {
        #expect(NewAgentModelRules.version(of: "Haiku 4.5") == [4, 5])
        #expect(NewAgentModelRules.version(of: "Haiku") == [])
    }

    // MARK: Starting model

    @Test func anEmptyFieldTakesHaikuForClaudeCode() {
        #expect(NewAgentModelRules.startingModel(
            current: "", chosen: false, runtime: .claude, models: Self.withHaikuId) == "haiku")
    }

    @Test func aListThatComesLaterStillSetsHaiku() {
        // The list is nil at first: nothing is set. When it arrives, the same call sets Haiku.
        #expect(NewAgentModelRules.startingModel(current: "", chosen: false, runtime: .claude, models: []) == "")
        #expect(NewAgentModelRules.startingModel(
            current: "", chosen: false, runtime: .claude, models: Self.withHaikuId) == "haiku")
    }

    @Test func aModelThePersonChoseIsNeverReplaced() {
        #expect(NewAgentModelRules.startingModel(
            current: "opus", chosen: true, runtime: .claude, models: Self.withHaikuId) == "opus")
    }

    @Test func choosingDefaultIsAChoiceToo() {
        #expect(NewAgentModelRules.startingModel(
            current: "", chosen: true, runtime: .claude, models: Self.withHaikuId) == "")
    }

    @Test func aModelAlreadySetIsKept() {
        #expect(NewAgentModelRules.startingModel(
            current: "sonnet", chosen: false, runtime: .claude, models: Self.withHaikuId) == "sonnet")
    }

    @Test func otherRuntimesKeepTheirEmptyModel() {
        #expect(NewAgentModelRules.startingModel(
            current: "", chosen: false, runtime: .codex, models: Self.withHaikuId) == "")
    }

    @Test func aTemplateSetModelWinsOverTheStartingModel() {
        // A template sets the model and marks it chosen, so Haiku does not replace it.
        var draft = NewAgentDraft()
        draft.model = "opus"
        draft.modelChosen = true
        draft.model = NewAgentModelRules.startingModel(
            current: draft.model, chosen: draft.modelChosen, runtime: .claude, models: Self.withHaikuId)
        #expect(draft.model == "opus")
    }

    @Test func aRuntimeRoundTripDoesNotResetAChosenModelToHaiku() {
        // Claude Code, the person picks Sonnet, goes to Codex and back. The model is not Haiku after the trip.
        var draft = NewAgentDraft()
        draft.model = "sonnet"
        draft.modelChosen = true
        let lists = ["claude": RuntimeModelList(runtime: .claude, models: Self.withHaikuId, fetchedAt: 1)]
        draft.setRuntime(.codex, lists: lists)
        draft.setRuntime(.claude, lists: lists)
        let model = NewAgentModelRules.startingModel(
            current: draft.model, chosen: draft.modelChosen, runtime: draft.runtime, models: Self.withHaikuId)
        #expect(model != "haiku")
    }

    @Test func aRuntimeRoundTripWithoutAChoiceStartsOnHaikuAgain() {
        var draft = NewAgentDraft()
        let lists = ["claude": RuntimeModelList(runtime: .claude, models: Self.withHaikuId, fetchedAt: 1)]
        draft.setRuntime(.codex, lists: lists)
        draft.setRuntime(.claude, lists: lists)
        draft.model = NewAgentModelRules.startingModel(
            current: draft.model, chosen: draft.modelChosen, runtime: draft.runtime, models: Self.withHaikuId)
        #expect(draft.model == "haiku")
    }
}
