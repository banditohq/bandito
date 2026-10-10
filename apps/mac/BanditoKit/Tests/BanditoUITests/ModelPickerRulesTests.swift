import BanditoKit
import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct ModelPickerRulesTests {
    static let list = RuntimeModelList(
        runtime: .claude,
        models: [
            RuntimeModel(id: "opus", name: "Opus 5.5", description: "For complex work", isDefault: true),
            RuntimeModel(id: "haiku", name: "Haiku 5.5", description: "Fast"),
        ],
        fetchedAt: 1)

    static let failedList = RuntimeModelList(runtime: .codex, models: [], error: "not_installed", fetchedAt: 1)

    // MARK: Options

    @Test func menuOffersTheListedModelsWithTheirNamesAndDescriptions() {
        let options = ModelPickerRules.options(list: Self.list, runtime: .claude)
        #expect(options.map(\.id) == ["opus", "haiku"])
        #expect(options.map(\.name) == ["Opus 5.5", "Haiku 5.5"])
        #expect(options.first?.description == "For complex work")
    }

    @Test func menuFallsBackToThePresetsWithoutAList() {
        let options = ModelPickerRules.options(list: nil, runtime: .claude)
        #expect(options.map(\.id) == ["opus", "sonnet", "haiku"])
        #expect(options.allSatisfy { $0.description == nil })
    }

    @Test func menuFallsBackToThePresetsWhenTheListIsEmpty() {
        let options = ModelPickerRules.options(list: Self.failedList, runtime: .claude)
        #expect(options.map(\.id) == ["opus", "sonnet", "haiku"])
    }

    @Test func codexWithoutAListOffersNothingButTheTypedId() {
        #expect(ModelPickerRules.options(list: nil, runtime: .codex).isEmpty)
    }

    // MARK: Typed selection

    @Test func noTypedSelectionForTheDefaultOrAListedModel() {
        let options = ModelPickerRules.options(list: Self.list, runtime: .claude)
        #expect(ModelPickerRules.typedSelection("", options: options) == nil)
        #expect(ModelPickerRules.typedSelection("haiku", options: options) == nil)
    }

    @Test func anUnlistedIdIsShownFirstAsTheTypedSelection() {
        let options = ModelPickerRules.options(list: Self.list, runtime: .claude)
        #expect(ModelPickerRules.typedSelection("gpt-x", options: options) == "gpt-x")
    }

    @Test func aPresetIsNotATypedSelectionWithoutAList() {
        let options = ModelPickerRules.options(list: nil, runtime: .claude)
        #expect(ModelPickerRules.typedSelection("opus", options: options) == nil)
        #expect(ModelPickerRules.typedSelection("my-api-model", options: options) == "my-api-model")
    }

    /// An id saved for an old daemon's runtime, when the new daemon has no list yet. The id is dropped on a program
    /// change: a model that is not a preset of the new program cannot be known to exist, and the old id must not go to
    /// the new program. This is deliberate, and the person can type the id again.
    @Test func ownIdIsDroppedWhenTheProgramChangesAndNoListIsKnown() {
        #expect(RuntimeModelDisplay.model(afterSwitchingTo: .claude, keeping: "my-api-model", lists: [:]) == "")
        #expect(isClear(RuntimeModelDisplay.modelChange(
            afterSwitchingTo: .claude, current: "my-api-model", lists: [:])))
    }

    private func isClear(_ change: FieldChange<String>?) -> Bool {
        if case .clear? = change { return true }
        return false
    }

    // MARK: Typing

    @Test func confirmedIdIsKept() {
        #expect(ModelPickerRules.valueAfterTyping("gpt-x", startedWith: "opus", submitted: true) == "gpt-x")
    }

    @Test func leavingWithoutReturnGoesBackToTheSavedValue() {
        #expect(ModelPickerRules.valueAfterTyping("gpt-half", startedWith: "opus", submitted: false) == "opus")
        #expect(ModelPickerRules.valueAfterTyping("gpt-half", startedWith: "", submitted: false) == "")
    }

    // MARK: Hints

    @Test func aListWithoutAnErrorHasNoHint() {
        #expect(ModelPickerRules.hint(list: Self.list, status: .loaded) == ModelListHint.none)
        #expect(ModelPickerRules.hint(list: Self.list, status: .failed("x")) == ModelListHint.none)
    }

    @Test func aListWithAnErrorIsTheRuntimeError() {
        #expect(ModelPickerRules.hint(list: Self.failedList, status: .loaded) == .runtimeError("not_installed"))
    }

    @Test func noListWhileAskingIsLoading() {
        #expect(ModelPickerRules.hint(list: nil, status: .unknown) == .loading)
    }

    @Test func anOldDaemonIsUnsupportedNotFailed() {
        let hint = ModelPickerRules.hint(list: nil, status: .unsupported)
        #expect(hint == .unsupported)
        #expect(!hint.isFailure)
    }

    @Test func aFailedRequestIsAFailureWithItsReason() {
        let hint = ModelPickerRules.hint(list: nil, status: .failed("timed out"))
        #expect(hint == .failed("timed out"))
        #expect(hint.isFailure)
    }

    @Test func aRuntimeErrorIsAFailureForTheMenu() {
        #expect(ModelListHint.runtimeError("not_installed").isFailure)
        #expect(!ModelListHint.none.isFailure)
    }
}
