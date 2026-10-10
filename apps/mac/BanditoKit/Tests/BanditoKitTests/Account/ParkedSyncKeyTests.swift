import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@Suite struct ParkedSyncKeyTests {
    private func key(_ byte: UInt8 = 7) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: byte, count: 32))
    }

    @Test func parkedKeyComesBackWithItsAccount() throws {
        let store = MemorySecretStore()
        try ParkedSyncKey.park(key(3), accountID: "acc-1", in: store)
        let parked = try #require(try ParkedSyncKey.loadParked(from: store))
        #expect(parked.accountID == "acc-1")
        #expect(parked.key.withUnsafeBytes { Data($0) } == Data(repeating: 3, count: 32))
    }

    @Test func theStoredFormatIsTheDocumentedJSON() throws {
        let store = MemorySecretStore()
        try ParkedSyncKey.park(key(), accountID: "acc-1", in: store)
        let raw = try #require(try store.load(account: ParkedSyncKey.keychainAccount))
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: String])
        #expect(json["account_id"] == "acc-1")
        #expect(json["key"] == Data(repeating: 7, count: 32).base64EncodedString())
    }

    @Test func nothingParkedLoadsAsNil() throws {
        #expect(try ParkedSyncKey.loadParked(from: MemorySecretStore()) == nil)
    }

    @Test func clearRemovesTheParkedKey() throws {
        let store = MemorySecretStore()
        try ParkedSyncKey.park(key(), accountID: "acc-1", in: store)
        try ParkedSyncKey.clearParked(in: store)
        #expect(try store.load(account: ParkedSyncKey.keychainAccount) == nil)
    }

    @Test func brokenJSONIsNilAndTheSlotIsCleared() throws {
        let store = MemorySecretStore()
        try store.save(Data("not json".utf8), account: ParkedSyncKey.keychainAccount)
        #expect(try ParkedSyncKey.loadParked(from: store) == nil)
        #expect(try store.load(account: ParkedSyncKey.keychainAccount) == nil)
    }

    @Test func aKeyOfTheWrongLengthIsNilAndTheSlotIsCleared() throws {
        let store = MemorySecretStore()
        let record = #"{"account_id":"acc-1","key":"\#(Data(repeating: 1, count: 16).base64EncodedString())"}"#
        try store.save(Data(record.utf8), account: ParkedSyncKey.keychainAccount)
        #expect(try ParkedSyncKey.loadParked(from: store) == nil)
        #expect(try store.load(account: ParkedSyncKey.keychainAccount) == nil)
    }

    @Test func anEmptyAccountIDIsNilAndTheSlotIsCleared() throws {
        let store = MemorySecretStore()
        let record = #"{"account_id":"","key":"\#(Data(repeating: 1, count: 32).base64EncodedString())"}"#
        try store.save(Data(record.utf8), account: ParkedSyncKey.keychainAccount)
        #expect(try ParkedSyncKey.loadParked(from: store) == nil)
        #expect(try store.load(account: ParkedSyncKey.keychainAccount) == nil)
    }

    @Test func noParkedKeyDecidesNone() {
        #expect(ParkedSyncKey.decide(parkedAccountID: nil, currentAccountID: "a", opensBlob: true) == .none)
    }

    @Test func anotherAccountDiscardsTheParkedKey() {
        #expect(ParkedSyncKey.decide(parkedAccountID: "b", currentAccountID: "a", opensBlob: true) == .discard)
        #expect(ParkedSyncKey.decide(parkedAccountID: "b", currentAccountID: "a", opensBlob: false) == .discard)
    }

    @Test func theSameAccountWhoseBlobOpensRestores() {
        #expect(ParkedSyncKey.decide(parkedAccountID: "a", currentAccountID: "a", opensBlob: true) == .restore)
    }

    @Test func theSameAccountWhoseBlobDoesNotOpenDiscards() {
        #expect(ParkedSyncKey.decide(parkedAccountID: "a", currentAccountID: "a", opensBlob: false) == .discard)
    }

    @Test func aParkedKeyOpensTheBlobOnlyWithTheRightAccountAndVersion() throws {
        let key = key(9)
        let payload = Data(#"{"version":1}"#.utf8)
        let blob = try SyncKey.sealBlob(
            payload, key: key, associatedData: SyncKey.blobAssociatedData(accountID: "a", version: 4))
        #expect(try SyncKey.openBlob(blob, key: key, associatedData: SyncKey.blobAssociatedData(accountID: "a", version: 4)) == payload)
        #expect(throws: SyncKeyError.cannotOpen) {
            try SyncKey.openBlob(blob, key: key, associatedData: SyncKey.blobAssociatedData(accountID: "b", version: 4))
        }
        #expect(throws: SyncKeyError.cannotOpen) {
            try SyncKey.openBlob(blob, key: self.key(1), associatedData: SyncKey.blobAssociatedData(accountID: "a", version: 4))
        }
    }

    /// Everything a sign-in writes from, as it is when a parked key restores: approved, a blob, no live key, the
    /// parked key of the same account that opens the blob, the session of that account, and no sign-out running.
    private func restoreInput(
        approved: Bool = true, hasBlob: Bool = true, hasMainKey: Bool = false, signingOut: Bool = false,
        parkedAccountID: String? = "a", opens: Bool = true, blobAccountID: String? = "a",
        sessionUserID: String? = "a", meUserID: String = "a"
    ) -> ParkedRestoreDecision {
        ParkedSyncKey.restoreDecision(
            approved: approved, hasBlob: hasBlob, hasMainKey: hasMainKey, signingOut: signingOut,
            parkedAccountID: parkedAccountID, blobOpensWithParked: opens,
            blobAccountID: blobAccountID, sessionUserID: sessionUserID, meUserID: meUserID)
    }

    @Test func aMatchingParkedKeyRestores() {
        #expect(restoreInput() == .restore)
    }

    @Test func aBlobThatDoesNotOpenWithTheSameAccountsParkedKeyDiscardsIt() {
        #expect(restoreInput(opens: false) == .discard)
    }

    @Test func aParkedKeyOfAnotherAccountIsDiscarded() {
        #expect(restoreInput(parkedAccountID: "b", opens: false) == .discard)
        #expect(restoreInput(parkedAccountID: "b", opens: true) == .discard)
    }

    @Test func aParkedKeyOfAnotherAccountIsDiscardedEvenWithoutAnyBlob() {
        #expect(restoreInput(hasBlob: false, parkedAccountID: "b", opens: false) == .discard)
    }

    @Test func aParkedKeyOfTheSameAccountWithoutABlobIsLeftAlone() {
        #expect(restoreInput(hasBlob: false, parkedAccountID: "a", opens: false) == .leave)
    }

    @Test func noParkedKeyWritesNothing() {
        #expect(restoreInput(parkedAccountID: nil) == .leave)
    }

    @Test func aSignOutInProgressWritesNothing() {
        #expect(restoreInput(signingOut: true) == .leave)
    }

    @Test func aSessionThatIsGoneWritesNothing() {
        #expect(restoreInput(sessionUserID: nil) == .leave)
    }

    @Test func aSessionOfAnotherAccountWritesNothing() {
        #expect(restoreInput(sessionUserID: "b") == .leave)
        #expect(restoreInput(opens: false, sessionUserID: "b") == .leave)
    }

    @Test func aMeOfAnotherAccountWritesNothing() {
        #expect(restoreInput(meUserID: "b") == .leave)
    }

    @Test func noBlobAccountWritesNothing() {
        #expect(restoreInput(blobAccountID: nil) == .leave)
    }

    @Test func aLiveKeyOrNoApprovalOrNoBlobWritesNothing() {
        #expect(restoreInput(hasMainKey: true) == .leave)
        #expect(restoreInput(approved: false) == .leave)
        #expect(restoreInput(hasBlob: false) == .leave)
    }
}
