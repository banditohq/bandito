import BanditoKit
import Testing

@testable import BanditoUI

/// Which integrations an agent uses: every enabled one, or a picked set that goes back to "every" when it matches.
@Suite struct IntegrationChoiceTests {
    @Test func aMissingListIsEveryEnabledOne() {
        #expect(IntegrationChoice.from(nil) == .all)
        #expect(IntegrationChoice.from(nil).wireIDs == nil)
        #expect(isClear(IntegrationChoice.from(nil).patchChange))
        #expect(IntegrationChoice.from(["b", "a"]).wireIDs == ["a", "b"])
        #expect(IntegrationChoice.from([]).wireIDs == [])
    }

    @Test func aClickInAllTurnsOneOffAndLeavesTheRest() {
        let enabled: Set<String> = ["a", "b", "c"]
        let next = IntegrationChoice.all.toggled("b", enabled: enabled)
        #expect(next == .picked(["a", "c"]))
        #expect(next.isOn("a", enabled: enabled))
        #expect(!next.isOn("b", enabled: enabled))
        #expect(next.toggled("b", enabled: enabled) == .all)
    }

    @Test func aDisabledIntegrationIsNotOnInAll() {
        #expect(!IntegrationChoice.all.isOn("off", enabled: ["a"]))
        #expect(IntegrationChoice.all.isOn("a", enabled: ["a"]))
    }

    @Test func pickingEveryEnabledOneIsAllAgain() {
        let enabled: Set<String> = ["a", "b"]
        let picked = IntegrationChoice.picked(["a"]).toggled("b", enabled: enabled)
        #expect(picked == .all)
        #expect(IntegrationChoice.picked([]).toggled("a", enabled: enabled) == .picked(["a"]))
    }

    @Test func patchAndCreateCarryThePickedIds() {
        #expect(IntegrationChoice.picked(["z", "m"]).wireIDs == ["m", "z"])
        #expect(setIDs(IntegrationChoice.picked(["z", "m"]).patchChange) == ["m", "z"])
        #expect(setIDs(IntegrationChoice.picked([]).patchChange) == [])
    }

    @Test func aPickedIdThatNoLongerExistsIsNotSent() {
        #expect(IntegrationChoice.picked(["a", "gone"]).limited(to: ["a", "b"]) == .picked(["a"]))
        #expect(IntegrationChoice.picked(["gone"]).limited(to: ["a"]) == .picked([]))
        #expect(IntegrationChoice.all.limited(to: ["a"]) == .all)
        #expect(setIDs(IntegrationChoice.picked(["a", "gone"]).limited(to: ["a"]).patchChange) == ["a"])
    }

    @Test func aNewAgentSendsTheChoiceOnlyWhenPicked() {
        var draft = NewAgentDraft()
        draft.cwd = "/work"
        #expect(draft.makeNewAgent().integrations == nil)
        draft.integrations = .picked(["b", "a"])
        #expect(draft.makeNewAgent().integrations == ["a", "b"])
    }
}

private func isClear(_ change: FieldChange<[String]>) -> Bool {
    if case .clear = change { return true }
    return false
}

private func setIDs(_ change: FieldChange<[String]>) -> [String]? {
    if case .set(let ids) = change { return ids }
    return nil
}
