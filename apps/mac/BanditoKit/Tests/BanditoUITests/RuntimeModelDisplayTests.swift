import BanditoKit
import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct RuntimeModelDisplayTests {
    /// A Claude list with a default model that takes effort and a model that takes none.
    static let claudeList = RuntimeModelList(
        runtime: .claude,
        models: [
            RuntimeModel(
                id: "opus", name: "Opus 5.5", description: "For complex work", isDefault: true,
                efforts: ["low", "medium", "high", "xhigh", "max"]),
            RuntimeModel(id: "haiku", name: "Haiku 5.5", description: "Fast", efforts: []),
        ],
        fetchedAt: 1)

    static let lists: [String: RuntimeModelList] = ["claude": claudeList]

    @Test func listedModelShowsItsName() {
        #expect(RuntimeModelDisplay.name(id: "haiku", runtime: .claude, lists: Self.lists) == "Haiku 5.5")
    }

    @Test func unlistedModelShowsItsId() {
        #expect(RuntimeModelDisplay.name(id: "claude-x-9", runtime: .claude, lists: Self.lists) == "claude-x-9")
        #expect(RuntimeModelDisplay.name(id: "haiku", runtime: .codex, lists: Self.lists) == "haiku")
        #expect(RuntimeModelDisplay.name(id: "haiku", runtime: .claude, lists: [:]) == "haiku")
    }

    @Test func defaultModelIsUsedForTheEmptySelection() {
        #expect(Self.claudeList.defaultModel?.name == "Opus 5.5")
        #expect(RuntimeModelDisplay.efforts(modelID: "", runtime: .claude, lists: Self.lists)
            == [.low, .medium, .high, .xhigh, .max])
    }

    @Test func listWithoutDefaultHasNoDefaultEfforts() {
        let list = RuntimeModelList(
            runtime: .grok, models: [RuntimeModel(id: "a", name: "A", efforts: ["low"])], fetchedAt: 1)
        #expect(list.defaultModel == nil)
        #expect(RuntimeModelDisplay.efforts(modelID: "", runtime: .grok, lists: ["grok": list]) == nil)
    }

    @Test func effortsOfAListedModel() {
        #expect(RuntimeModelDisplay.efforts(modelID: "opus", runtime: .claude, lists: Self.lists)
            == [.low, .medium, .high, .xhigh, .max])
    }

    @Test func modelWithoutEffortsTakesNoEffort() {
        #expect(RuntimeModelDisplay.efforts(modelID: "haiku", runtime: .claude, lists: Self.lists) == [])
    }

    @Test func effortsAreUnknownForAnUnlistedModelOrNoList() {
        #expect(RuntimeModelDisplay.efforts(modelID: "gpt-x", runtime: .claude, lists: Self.lists) == nil)
        #expect(RuntimeModelDisplay.efforts(modelID: "opus", runtime: .codex, lists: Self.lists) == nil)
    }

    @Test func switchKeepsAModelTheNewListNames() {
        let kept = RuntimeModelDisplay.model(afterSwitchingTo: .claude, keeping: "haiku", lists: Self.lists)
        #expect(kept == "haiku")
    }

    @Test func switchDropsAModelTheNewListLacks() {
        let dropped = RuntimeModelDisplay.model(afterSwitchingTo: .claude, keeping: "gpt-x", lists: Self.lists)
        #expect(dropped == "")
    }

    @Test func switchWithoutAListKeepsOnlyAPreset() {
        #expect(RuntimeModelDisplay.model(afterSwitchingTo: .claude, keeping: "opus", lists: [:]) == "opus")
        #expect(RuntimeModelDisplay.model(afterSwitchingTo: .claude, keeping: "gpt-x", lists: [:]) == "")
        #expect(RuntimeModelDisplay.model(afterSwitchingTo: .codex, keeping: "opus", lists: [:]) == "")
    }

    @Test func effortLevelsAreTheModelsOwnOrTheRuntimes() {
        #expect(RuntimeModelDisplay.effortLevels(modelID: "opus", runtime: .claude, lists: Self.lists)
            == [.low, .medium, .high, .xhigh, .max])
        #expect(RuntimeModelDisplay.effortLevels(modelID: "haiku", runtime: .claude, lists: Self.lists) == [])
        #expect(RuntimeModelDisplay.effortLevels(modelID: "gpt-x", runtime: .claude, lists: Self.lists)
            == RuntimeKind.claude.supportedEfforts)
        #expect(RuntimeModelDisplay.effortLevels(modelID: "", runtime: .codex, lists: [:])
            == RuntimeKind.codex.supportedEfforts)
    }

    @Test func effortIsMovedToTheNearestLevelTheModelTakes() {
        let grok = RuntimeModelList(
            runtime: .grok,
            models: [RuntimeModel(id: "g", name: "G", efforts: ["high", "max"])],
            fetchedAt: 1)
        let lists = ["grok": grok]
        #expect(RuntimeModelDisplay.effort(.low, modelID: "g", runtime: .grok, lists: lists) == .high)
        #expect(RuntimeModelDisplay.effort(.max, modelID: "g", runtime: .grok, lists: lists) == .max)
    }

    @Test func effortIsNilForAModelThatTakesNone() {
        #expect(RuntimeModelDisplay.effort(.max, modelID: "haiku", runtime: .claude, lists: Self.lists) == nil)
    }

    @Test func effortIsKeptWhenTheListDoesNotSayAnything() {
        #expect(RuntimeModelDisplay.effort(.max, modelID: "gpt-x", runtime: .claude, lists: Self.lists) == .max)
        #expect(RuntimeModelDisplay.effort(.max, modelID: "", runtime: .codex, lists: [:]) == .max)
    }

    @Test func modelChangeOfASwitchKeepsOrClearsTheModel() {
        #expect(RuntimeModelDisplay.modelChange(afterSwitchingTo: .claude, current: "", lists: Self.lists) == nil)
        guard case .set("haiku")? = RuntimeModelDisplay.modelChange(
            afterSwitchingTo: .claude, current: "haiku", lists: Self.lists)
        else {
            Issue.record("a model the new list names is sent as set")
            return
        }
        guard case .clear? = RuntimeModelDisplay.modelChange(
            afterSwitchingTo: .codex, current: "opus", lists: Self.lists)
        else {
            Issue.record("a model the new list lacks is sent as clear")
            return
        }
    }

    @Test func emptyModelStaysEmpty() {
        #expect(RuntimeModelDisplay.model(afterSwitchingTo: .codex, keeping: "", lists: Self.lists) == "")
    }
}

extension RuntimeModelDisplayTests {
    static let grokList = RuntimeModelList(
        runtime: .grok,
        models: [RuntimeModel(id: "g", name: "G", efforts: ["low", "high"])],
        fetchedAt: 1)

    @Test func openingOrListArrivalWritesNoEffort() {
        // The same model before and after: the list arriving changes what the picker shows, not what is saved.
        let written = RuntimeModelDisplay.effortWrite(
            modelChangedFrom: "opus", to: "opus", stored: .max, runtime: .claude, lists: Self.lists)
        #expect(written == nil)
    }

    @Test func modelChangeMovesAStoredEffortTheNewModelLacks() {
        let written = RuntimeModelDisplay.effortWrite(
            modelChangedFrom: "opus", to: "g", stored: .max, runtime: .grok, lists: ["grok": Self.grokList])
        #expect(written == .high)
    }

    @Test func modelChangeWritesNothingWhenTheStoredEffortFits() {
        let written = RuntimeModelDisplay.effortWrite(
            modelChangedFrom: "opus", to: "g", stored: .low, runtime: .grok, lists: ["grok": Self.grokList])
        #expect(written == nil)
    }

    @Test func modelChangeToAModelWithoutEffortWritesNoEffort() {
        let written = RuntimeModelDisplay.effortWrite(
            modelChangedFrom: "opus", to: "haiku", stored: .max, runtime: .claude, lists: Self.lists)
        #expect(written == nil)
    }

    @Test func modelChangeWithoutAStoredEffortOrAListWritesNothing() {
        #expect(RuntimeModelDisplay.effortWrite(
            modelChangedFrom: "opus", to: "g", stored: nil, runtime: .grok, lists: ["grok": Self.grokList]) == nil)
        #expect(RuntimeModelDisplay.effortWrite(
            modelChangedFrom: "opus", to: "gpt-x", stored: .max, runtime: .claude, lists: Self.lists) == nil)
    }

    @Test func effortIsHiddenForAModelWithEmptyEfforts() {
        // The inspector and the sheet hide the control when the levels are empty, and send no effort.
        #expect(RuntimeModelDisplay.effortLevels(modelID: "haiku", runtime: .claude, lists: Self.lists).isEmpty)
        #expect(RuntimeModelDisplay.effort(.max, modelID: "haiku", runtime: .claude, lists: Self.lists) == nil)
    }
}

@Suite struct NewAgentDraftModelResetTests {
    @Test func switchingRuntimeDropsTheModelTheNewOneLacks() {
        var draft = NewAgentDraft()
        draft.model = "opus"
        draft.setRuntime(.codex, lists: ["codex": RuntimeModelList(
            runtime: .codex, models: [RuntimeModel(id: "gpt-5", name: "GPT-5", isDefault: true)], fetchedAt: 1)])
        #expect(draft.model == "")
        #expect(draft.runtime == .codex)
    }

    @Test func choosingTheSameRuntimeKeepsTheModel() {
        var draft = NewAgentDraft()
        draft.model = "gpt-x"
        draft.setRuntime(.claude)
        #expect(draft.model == "gpt-x")
    }

    @Test func switchingRuntimeKeepsAModelTheNewListNames() {
        var draft = NewAgentDraft()
        draft.model = "haiku"
        draft.setRuntime(.codex, lists: ["codex": RuntimeModelList(
            runtime: .codex, models: [RuntimeModel(id: "haiku", name: "Haiku")], fetchedAt: 1)])
        #expect(draft.model == "haiku")
    }

    @Test func fallbackRuntimeChangeDropsItsModel() {
        var draft = NewAgentDraft()
        draft.setFallbackRuntime(.grok)
        draft.fallbackModel = "grok-x"
        draft.setFallbackRuntime(.codex)
        #expect(draft.fallbackModel == "")
        #expect(draft.fallbackRuntime == .codex)
    }

    @Test func clearingTheFallbackClearsItsModel() {
        var draft = NewAgentDraft()
        draft.setFallbackRuntime(.codex)
        draft.fallbackModel = "gpt-5"
        draft.setFallbackRuntime(nil)
        #expect(draft.fallbackModel == "")
        #expect(draft.fallbackRuntime == nil)
    }
}

@Suite struct NewAgentDraftEffortTests {
    @Test func aModelThatTakesNoEffortIsCreatedWithoutOne() {
        var draft = NewAgentDraft()
        draft.model = "haiku"
        draft.effort = .max
        #expect(draft.makeNewAgent(lists: RuntimeModelDisplayTests.lists).effort == nil)
    }

    @Test func theEffortIsMovedToALevelTheModelTakes() {
        var draft = NewAgentDraft()
        draft.model = "opus"
        draft.effort = .max
        let listed = RuntimeModelList(
            runtime: .claude, models: [RuntimeModel(id: "opus", name: "Opus", efforts: ["low", "high"])],
            fetchedAt: 1)
        #expect(draft.makeNewAgent(lists: ["claude": listed]).effort == .high)
    }

    @Test func theChosenEffortIsKeptWhenTheListIsUnknown() {
        var draft = NewAgentDraft()
        draft.model = "opus"
        draft.effort = .max
        #expect(draft.makeNewAgent().effort == .max)
        #expect(draft.makeNewAgent(lists: RuntimeModelDisplayTests.lists).effort == .max)
    }
}

