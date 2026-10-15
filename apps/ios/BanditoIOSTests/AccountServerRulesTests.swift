import BanditoKit
import Foundation
import Testing

@testable import Bandito

@Suite struct AccountServerRulesTests {
    private let phone = SyncedPhone(sid: "S1", relayHost: "relay.bandito.dev", nk: "NK")

    private func state(_ status: AccessServerState.Status, name: String = "vps", id: UUID = UUID()) -> AccessServerState {
        AccessServerState(id: id, name: name, status: status, phone: phone)
    }

    @Test func eachStatusHasItsNote() {
        #expect(AccountServerRules.note(for: .waitingForMac, fastPolling: true) == .waitingForMac)
        #expect(AccountServerRules.note(for: .noRemoteAccess, fastPolling: true) == .noRemoteAccess)
        #expect(AccountServerRules.note(for: .updateNeeded, fastPolling: false) == .updateNeeded)
        #expect(AccountServerRules.note(for: .connected, fastPolling: true) == nil)
        #expect(AccountServerRules.note(for: .hidden, fastPolling: true) == nil)
    }

    @Test func aServerThatKeepsWaitingAfterTheFastStretchMeansTheMacIsOff() {
        #expect(AccountServerRules.note(for: .waitingForMac, fastPolling: false) == .macOffline)
        // Only a waiting server changes with the pace.
        #expect(AccountServerRules.note(for: .noRemoteAccess, fastPolling: false) == .noRemoteAccess)
    }

    @Test func onlyAWaitingServerShowsASpinner() {
        #expect(AccountServerNote.waitingForMac.isWorking)
        #expect(!AccountServerNote.macOffline.isWorking && !AccountServerNote.noRemoteAccess.isWorking)
    }

    @Test func rowsLeaveOutConnectedHiddenAndHeldServersAndKeepTheOrder() {
        let held = UUID()
        let servers = [
            state(.waitingForMac, name: "A"), state(.connected, name: "B"), state(.hidden, name: "C"),
            state(.noRemoteAccess, name: "D"), state(.waitingForMac, name: "E", id: held),
        ]
        let rows = AccountServerRules.rows(from: servers, fastPolling: true, holds: { id, _ in id == held })
        #expect(rows.map(\.name) == ["A", "D"])
        #expect(rows.map(\.note) == [.waitingForMac, .noRemoteAccess])
    }

    @Test func aServerAddedByHandUnderAnotherIdIsNotListedTwice() {
        let rows = AccountServerRules.rows(
            from: [state(.waitingForMac)], fastPolling: true, holds: { _, phone in phone != nil })
        #expect(rows.isEmpty)
    }
}
