import BanditoKit
import BanditoL10n
import CryptoKit
import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoUI

/// Scripted approval backend: the envelope answers come in order, approve and delete calls are recorded.
actor FakeApprovalBackend: DeviceApprovalBackend {
    private var envelopes: [Envelope?]
    private(set) var envelopeCalls = 0
    private(set) var approveCalls: [String] = []
    private(set) var deleteCalls: [(id: String, force: Bool)] = []
    private var networkFailures: Int
    private var cancelNext: Bool

    init(envelopes: [Envelope?] = [], networkFailures: Int = 0, cancelNext: Bool = false) {
        self.envelopes = envelopes
        self.networkFailures = networkFailures
        self.cancelNext = cancelNext
    }

    func myEnvelope() async throws -> Envelope? {
        envelopeCalls += 1
        if cancelNext {
            cancelNext = false
            throw CancellationError()
        }
        if networkFailures > 0 {
            networkFailures -= 1
            throw AccountError.network("offline")
        }
        guard !envelopes.isEmpty else { return nil }
        return envelopes.removeFirst()
    }

    func pendingDevices() async throws -> [PendingDevice] {
        []
    }

    func approve(
        _ device: PendingDevice, confirmedFingerprint: String, syncKey: SymmetricKey, identity: DeviceIdentity
    ) async throws {
        approveCalls.append(confirmedFingerprint)
    }

    func deleteDevice(id: String, force: Bool) async throws {
        deleteCalls.append((id, force))
    }
}

@Suite struct AccountRouteTests {
    @Test func notApprovedWaitsForAnotherDevice() {
        #expect(AccountRoute.decide(approved: false, hasBlob: false, hasKey: false) == .waitForApproval)
        #expect(AccountRoute.decide(approved: false, hasBlob: true, hasKey: true) == .waitForApproval)
    }

    @Test func approvedWithoutSyncDataIsTheFirstDevice() {
        #expect(AccountRoute.decide(approved: true, hasBlob: false, hasKey: false) == .firstDevice)
        #expect(AccountRoute.decide(approved: true, hasBlob: false, hasKey: true) == .firstDevice)
    }

    @Test func approvedWithDataAndKeyIsReady() {
        #expect(AccountRoute.decide(approved: true, hasBlob: true, hasKey: true) == .ready)
    }

    @Test func approvedWithDataButNoKeyNeedsRecovery() {
        #expect(AccountRoute.decide(approved: true, hasBlob: true, hasKey: false) == .recoverRequired)
    }
}

@Suite struct DeviceCodeInputTests {
    @Test func pastingAnyFormatGivesTheGroupedCode() {
        var input = DeviceCodeInput()
        // Base32 has only A-Z and 2-7; the pasted text mixes case, spaces and dashes.
        input.enter("k7qf 2mxa-7rte h4wb")
        #expect(input.value == "K7QF-2MXA-7RTE-H4WB")
        #expect(input.raw == "K7QF2MXA7RTEH4WB")
        #expect(input.isComplete)
    }

    @Test func charactersOutsideTheCodeAlphabetAreDropped() {
        var input = DeviceCodeInput()
        // 0, 1, 8 and 9 are not in base32; punctuation is dropped.
        input.enter("0a1b8c9d!?")
        #expect(input.raw == "ABCD")
        #expect(!input.isComplete)
    }

    @Test func longerInputIsCutAtSixteenCharacters() {
        var input = DeviceCodeInput()
        input.enter("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        #expect(input.raw.count == 16)
        #expect(input.value == "ABCD-EFGH-IJKL-MNOP")
    }

    @Test func partialInputIsGroupedAsItGrows() {
        var input = DeviceCodeInput()
        input.enter("K7Q")
        #expect(input.value == "K7Q")
        input.enter("K7QF2")
        #expect(input.value == "K7QF-2")
    }
}

@MainActor
@Suite struct DeviceApprovalModelTests {
    private func identities() throws -> (approver: DeviceIdentity, newcomer: DeviceIdentity) {
        let approver = try DeviceIdentity.make(from: MemorySecretStore())
        let newcomer = try DeviceIdentity.make(from: MemorySecretStore())
        return (approver, newcomer)
    }

    @Test func pollingStopsAtTheEnvelope() async throws {
        let ids = try identities()
        let envelope = try SyncKey.seal(
            SymmetricKey(size: .bits256), forPublicKey: ids.newcomer.publicKeyBase64, sender: ids.approver,
            accountID: "acc", deviceID: "dev")
        let backend = FakeApprovalBackend(envelopes: [nil, nil, Envelope(envelope: envelope, fromPublicKey: "")])
        let model = DeviceApprovalModel(
            backend: backend, identity: ids.newcomer, accountID: "acc", deviceID: "dev",
            keys: MemorySecretStore(), sleep: { _ in })
        await model.runPolling()
        #expect(await backend.envelopeCalls == 3)
        #expect(model.polls == 3)
        #expect(model.phase == .confirmSender(senderCode: DeviceFingerprint.code(publicKey: ids.approver.agreementKey.publicKey.rawRepresentation)))
    }

    @Test func leavingTheScreenStopsPolling() async throws {
        let ids = try identities()
        let backend = FakeApprovalBackend(envelopes: [])
        let model = DeviceApprovalModel(
            backend: backend, identity: ids.newcomer, accountID: "acc", deviceID: "dev",
            keys: MemorySecretStore(), sleep: { _ in })
        let task = Task { await model.runPolling() }
        task.cancel()
        await task.value
        #expect(await backend.envelopeCalls == 0)
        #expect(model.phase == .waiting)
    }

    @Test func aNetworkErrorIsRetriedNotTreatedAsTheEnd() async throws {
        let ids = try identities()
        let envelope = try SyncKey.seal(
            SymmetricKey(size: .bits256), forPublicKey: ids.newcomer.publicKeyBase64, sender: ids.approver,
            accountID: "acc", deviceID: "dev")
        let backend = FakeApprovalBackend(envelopes: [Envelope(envelope: envelope, fromPublicKey: "")], networkFailures: 2)
        let model = DeviceApprovalModel(
            backend: backend, identity: ids.newcomer, accountID: "acc", deviceID: "dev",
            keys: MemorySecretStore(), sleep: { _ in })
        await model.runPolling()
        #expect(await backend.envelopeCalls == 3)
        guard case .confirmSender = model.phase else {
            Issue.record("expected confirmSender, got \(model.phase)")
            return
        }
    }

    @Test func confirmingTheSenderKeepsTheSyncKey() async throws {
        let ids = try identities()
        let key = SymmetricKey(size: .bits256)
        let envelope = try SyncKey.seal(
            key, forPublicKey: ids.newcomer.publicKeyBase64, sender: ids.approver, accountID: "acc", deviceID: "dev")
        let backend = FakeApprovalBackend(envelopes: [Envelope(envelope: envelope, fromPublicKey: "")])
        let keys = MemorySecretStore()
        let model = DeviceApprovalModel(
            backend: backend, identity: ids.newcomer, accountID: "acc", deviceID: "dev",
            keys: keys, sleep: { _ in })
        _ = await model.pollOnce()
        try model.confirmSender()
        #expect(model.phase == .finished)
        let stored = try SyncKey.load(from: keys)
        #expect(stored?.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
    }

    @Test func rejectingDropsTheKey() async throws {
        let ids = try identities()
        let envelope = try SyncKey.seal(
            SymmetricKey(size: .bits256), forPublicKey: ids.newcomer.publicKeyBase64, sender: ids.approver,
            accountID: "acc", deviceID: "dev")
        let backend = FakeApprovalBackend(envelopes: [Envelope(envelope: envelope, fromPublicKey: "")])
        let keys = MemorySecretStore()
        let model = DeviceApprovalModel(
            backend: backend, identity: ids.newcomer, accountID: "acc", deviceID: "dev",
            keys: keys, sleep: { _ in })
        _ = await model.pollOnce()
        _ = await model.refuse()
        #expect(model.phase == .rejected)
        #expect(try SyncKey.load(from: keys) == nil)
    }
}

@MainActor
@Suite struct ApproveDeviceModelTests {
    private func identities() throws -> (approver: DeviceIdentity, newcomer: DeviceIdentity) {
        (try DeviceIdentity.make(from: MemorySecretStore()), try DeviceIdentity.make(from: MemorySecretStore()))
    }

    private func pendingDevice(for identity: DeviceIdentity) -> PendingDevice {
        PendingDevice(id: "dev-2", name: "iPhone", platform: "ios", publicKey: identity.publicKeyBase64,
                      createdAt: "2026-10-09T10:00:00Z")
    }

    @Test func matchingCodeSendsTheKeyOnce() async throws {
        let approver = try DeviceIdentity.make(from: MemorySecretStore())
        let newcomer = try DeviceIdentity.make(from: MemorySecretStore())
        let backend = FakeApprovalBackend()
        let model = ApproveDeviceModel(
            device: pendingDevice(for: newcomer), backend: backend, identity: approver,
            syncKey: { SymmetricKey(size: .bits256) })
        model.enter(DeviceFingerprint.code(publicKey: newcomer.agreementKey.publicKey.rawRepresentation))
        #expect(model.canApprove)
        await model.approve()
        await model.approve()
        #expect(await backend.approveCalls.count == 1)
        #expect(model.approved)
    }

    @Test func mismatchNeverReachesTheServer() async throws {
        let approver = try DeviceIdentity.make(from: MemorySecretStore())
        let newcomer = try DeviceIdentity.make(from: MemorySecretStore())
        let backend = FakeApprovalBackend()
        let model = ApproveDeviceModel(
            device: pendingDevice(for: newcomer), backend: backend, identity: approver,
            syncKey: { SymmetricKey(size: .bits256) })
        model.enter("AAAA-BBBB-CCCC-DDDD")
        #expect(model.canApprove)
        await model.approve()
        #expect(await backend.approveCalls.isEmpty)
        #expect(model.errorText == L10n.Onboarding.Account.codeMismatch)
        #expect(!model.approved)
    }

    @Test func anIncompleteCodeDoesNothing() async throws {
        let approver = try DeviceIdentity.make(from: MemorySecretStore())
        let newcomer = try DeviceIdentity.make(from: MemorySecretStore())
        let backend = FakeApprovalBackend()
        let model = ApproveDeviceModel(
            device: pendingDevice(for: newcomer), backend: backend, identity: approver,
            syncKey: { SymmetricKey(size: .bits256) })
        model.enter("K7QF")
        #expect(!model.canApprove)
        await model.approve()
        #expect(await backend.approveCalls.isEmpty)
    }

    @Test func rejectingRemovesTheDeviceWithoutForce() async throws {
        let approver = try DeviceIdentity.make(from: MemorySecretStore())
        let newcomer = try DeviceIdentity.make(from: MemorySecretStore())
        let backend = FakeApprovalBackend()
        let model = ApproveDeviceModel(
            device: pendingDevice(for: newcomer), backend: backend, identity: approver,
            syncKey: { SymmetricKey(size: .bits256) })
        #expect(await model.reject())
        #expect(await backend.deleteCalls.count == 1)
        #expect(await backend.deleteCalls.first?.id == "dev-2")
        #expect(await backend.deleteCalls.first?.force == false)
    }

    @Test func cancellationDuringAPollIsNotAFailure() async throws {
        let ids = try identities()
        let backend = FakeApprovalBackend(envelopes: [], cancelNext: true)
        let model = DeviceApprovalModel(
            backend: backend, identity: ids.newcomer, accountID: "acc", deviceID: "dev",
            keys: MemorySecretStore(), sleep: { _ in })
        let stopped = await model.pollOnce()
        #expect(stopped == false)
        #expect(model.phase == .waiting)
    }

    @Test func refusingRemovesThisDeviceFromTheAccount() async throws {
        let ids = try identities()
        let backend = FakeApprovalBackend(envelopes: [])
        let model = DeviceApprovalModel(
            backend: backend, identity: ids.newcomer, accountID: "acc", deviceID: "dev-me",
            keys: MemorySecretStore(), sleep: { _ in })
        let removed = await model.refuse()
        #expect(removed)
        #expect(model.phase == .rejected)
        #expect(await backend.deleteCalls.first?.id == "dev-me")
        #expect(await backend.deleteCalls.first?.force == false)
    }
}
