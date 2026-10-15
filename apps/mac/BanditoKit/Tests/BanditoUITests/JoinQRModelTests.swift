import BanditoKit
import CryptoKit
import Foundation
import Testing

@testable import BanditoUI

/// A scripted account service: the status answers are set by the test, every call is recorded.
actor FakeJoinBackend: JoinQRBackend {
    private(set) var created: [String] = []
    private(set) var cancelled: [String] = []
    private(set) var approvals: [(device: String, code: String)] = []
    private(set) var deleted: [String] = []
    private(set) var statusCalls = 0
    private var status: TicketStatus = .open
    private var createError: Error?
    private var approveErrors: [Error] = []
    private var failDelete = false
    private var lifetime: TimeInterval = 300

    func setStatus(_ value: TicketStatus) { status = value }
    func setCreateError(_ error: Error?) { createError = error }
    func setApproveErrors(_ errors: [Error]) { approveErrors = errors }
    func setFailDelete(_ value: Bool) { failDelete = value }
    func setLifetime(_ value: TimeInterval) { lifetime = value }

    func createTicket(hash: String) async throws -> (id: String, expiresAt: Date) {
        if let createError { throw createError }
        created.append(hash)
        return ("ticket-\(created.count)", Date().addingTimeInterval(lifetime))
    }

    func ticketStatus(id: String) async throws -> TicketStatus {
        statusCalls += 1
        return status
    }

    func cancelTicket(id: String) async throws { cancelled.append(id) }

    func approve(_ device: PendingDevice, confirmedFingerprint: String, syncKey: SymmetricKey) async throws {
        approvals.append((device.id, confirmedFingerprint))
        if !approveErrors.isEmpty { throw approveErrors.removeFirst() }
    }

    func deleteDevice(id: String, force: Bool) async throws {
        deleted.append(id)
        if failDelete { throw AccountError.network("offline") }
    }
}

@MainActor
@Suite struct JoinQRModelTests {
    private let phoneKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    private let phoneSigning = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()

    private final class Flags: @unchecked Sendable {
        // @unchecked: only touched from the main actor.
        var approved = 0
        var finished = 0
    }

    private func make(
        _ backend: FakeJoinBackend, blocker: JoinQRBlocker? = nil, hasKey: Bool = true, flags: Flags = Flags()
    ) -> JoinQRModel {
        JoinQRModel(
            backend: backend, macPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey, macName: "Studio 🦝",
            blocker: { blocker }, syncKey: { hasKey ? SymmetricKey(size: .bits256) : nil },
            onApproved: { flags.approved += 1 }, onFinished: { flags.finished += 1 },
            pollInterval: .milliseconds(5), finishDelay: .milliseconds(20))
    }

    private func wait(_ model: JoinQRModel, _ check: @MainActor (JoinQRModel.Phase) -> Bool) async -> Bool {
        for _ in 0..<400 {
            if check(model.phase) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return check(model.phase)
    }

    private func isShowing(_ phase: JoinQRModel.Phase) -> Bool {
        if case .showing = phase { return true }
        return false
    }

    private func ticket(of model: JoinQRModel) -> JoinTicket? {
        guard case .showing(let link, _) = model.phase else { return nil }
        return JoinTicket.parse(link)
    }

    private func claimed(_ ticket: JoinTicket, proofOK: Bool = true) -> TicketStatus {
        let proof = JoinProof.make(
            macKey: proofOK ? ticket.macKey : SymmetricKey(size: .bits256), publicKey: phoneKey, signingKey: phoneSigning)
        let device = ClaimedDevice(
            id: "phone-1", name: "Anna’s iPhone", platform: "ios", publicKey: phoneKey, signingKey: phoneSigning)
        return .claimed(device: device, proof: proof)
    }

    @Test func showsTheTicketLinkOfThisMac() async throws {
        let backend = FakeJoinBackend()
        let model = make(backend)
        model.start()
        #expect(await wait(model, isShowing))
        let ticket = try #require(ticket(of: model))
        #expect(ticket.macName == "Studio 🦝")
        #expect(await backend.created == [ticket.ticketHash])
        model.close()
    }

    @Test func aMacThatCannotLetADeviceInShowsWhyAndMakesNoTicket() async {
        for reason in [JoinQRBlocker.signedOut, .notApproved, .noSyncKey] {
            let backend = FakeJoinBackend()
            let model = make(backend, blocker: reason)
            model.start()
            #expect(await wait(model) { $0 == .blocked(reason) })
            #expect(await backend.created.isEmpty)
        }
    }

    @Test func aFailedTicketShowsTheErrorAndNewCodeTriesAgain() async {
        let backend = FakeJoinBackend()
        await backend.setCreateError(AccountError.network("offline"))
        let model = make(backend)
        model.start()
        #expect(await wait(model) { if case .failed = $0 { true } else { false } })
        await backend.setCreateError(nil)
        model.newCode()
        #expect(await wait(model, isShowing))
        model.close()
    }

    @Test func claimingIsShownWhileTheDeviceIsLinked() async {
        let backend = FakeJoinBackend()
        let model = make(backend)
        model.start()
        #expect(await wait(model, isShowing))
        await backend.setStatus(.claiming)
        #expect(await wait(model) { if case .claiming = $0 { true } else { false } })
        model.close()
    }

    @Test func aGoodProofSealsTheKeyApprovesAndClosesTheSheetByItself() async throws {
        let backend = FakeJoinBackend()
        let flags = Flags()
        let model = make(backend, flags: flags)
        model.start()
        #expect(await wait(model, isShowing))
        let ticket = try #require(ticket(of: model))
        await backend.setStatus(claimed(ticket))
        #expect(await wait(model) { $0 == .added(name: "Anna’s iPhone") })
        let approvals = await backend.approvals
        #expect(approvals.count == 1)
        #expect(approvals.first?.device == "phone-1")
        #expect(approvals.first?.code == (try DeviceFingerprint.code(publicKeyBase64: phoneKey)))
        #expect(await backend.deleted.isEmpty)
        #expect(flags.approved == 1)
        for _ in 0..<200 where flags.finished == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(flags.finished == 1)
        model.close()
    }

    @Test func aWrongProofIsNeverApprovedAndTheDeviceIsRemoved() async throws {
        let backend = FakeJoinBackend()
        let model = make(backend)
        model.start()
        #expect(await wait(model, isShowing))
        let ticket = try #require(ticket(of: model))
        await backend.setStatus(claimed(ticket, proofOK: false))
        #expect(await wait(model) { $0 == .badProof(removed: true) })
        #expect(await backend.approvals.isEmpty)
        #expect(await backend.deleted == ["phone-1"])
        model.close()
    }

    @Test func aWrongProofWhoseRemovalFailsSaysSo() async throws {
        let backend = FakeJoinBackend()
        await backend.setFailDelete(true)
        let model = make(backend)
        model.start()
        #expect(await wait(model, isShowing))
        let ticket = try #require(ticket(of: model))
        await backend.setStatus(claimed(ticket, proofOK: false))
        #expect(await wait(model) { $0 == .badProof(removed: false) })
        #expect(await backend.approvals.isEmpty)
        model.close()
    }

    @Test func aProofOfOtherKeysIsWrongToo() async throws {
        let backend = FakeJoinBackend()
        let model = make(backend)
        model.start()
        #expect(await wait(model, isShowing))
        let ticket = try #require(ticket(of: model))
        // The proof is good for the device keys of `phoneKey`, but the cloud reports another public key.
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let proof = JoinProof.make(macKey: ticket.macKey, publicKey: phoneKey, signingKey: phoneSigning)
        await backend.setStatus(
            .claimed(
                device: ClaimedDevice(id: "p", name: "x", platform: "ios", publicKey: other, signingKey: phoneSigning),
                proof: proof))
        #expect(await wait(model) { $0 == .badProof(removed: true) })
        #expect(await backend.approvals.isEmpty)
        model.close()
    }

    @Test func anApprovalThatFailsOnTheNetworkIsRepeatedAtTheNextLook() async throws {
        let backend = FakeJoinBackend()
        await backend.setApproveErrors([AccountError.network("offline"), AccountError.api(code: "http_502", status: 502)])
        let model = make(backend)
        model.start()
        #expect(await wait(model, isShowing))
        let ticket = try #require(ticket(of: model))
        await backend.setStatus(claimed(ticket))
        #expect(await wait(model) { $0 == .added(name: "Anna’s iPhone") })
        #expect(await backend.approvals.count == 3)
        model.close()
    }

    @Test func aDeviceThatIsAlreadyApprovedCountsAsAdded() async throws {
        let backend = FakeJoinBackend()
        await backend.setApproveErrors([AccountError.api(code: "already_approved", status: 409)])
        let model = make(backend)
        model.start()
        #expect(await wait(model, isShowing))
        let ticket = try #require(ticket(of: model))
        await backend.setStatus(claimed(ticket))
        #expect(await wait(model) { $0 == .added(name: "Anna’s iPhone") })
        model.close()
    }

    @Test func anApprovalRefusedForGoodStopsWithTheError() async throws {
        let backend = FakeJoinBackend()
        await backend.setApproveErrors([AccountError.api(code: "device_not_approved", status: 403)])
        let model = make(backend)
        model.start()
        #expect(await wait(model, isShowing))
        let ticket = try #require(ticket(of: model))
        await backend.setStatus(claimed(ticket))
        #expect(await wait(model) { if case .failed = $0 { true } else { false } })
        #expect(await backend.approvals.count == 1)
        model.close()
    }

    @Test func withoutTheSyncKeyAtTheLastMomentNothingIsApproved() async throws {
        let backend = FakeJoinBackend()
        let model = make(backend, hasKey: false)
        model.start()
        #expect(await wait(model, isShowing))
        let ticket = try #require(ticket(of: model))
        await backend.setStatus(claimed(ticket))
        #expect(await wait(model) { if case .failed = $0 { true } else { false } })
        #expect(await backend.approvals.isEmpty)
        model.close()
    }

    @Test func aTicketThatRanOutIsReplacedUpToThreeTimesThenTheButtonShows() async {
        let backend = FakeJoinBackend()
        await backend.setStatus(.expired)
        let model = make(backend)
        model.start()
        #expect(await wait(model) { $0 == .expired })
        // The first ticket and three automatic ones.
        #expect(await backend.created.count == 4)
        // The person asks for the next code: the count starts again.
        await backend.setStatus(.open)
        model.newCode()
        #expect(await wait(model, isShowing))
        #expect(await backend.created.count == 5)
        model.close()
    }

    @Test func aTicketWhoseTimePassedLocallyIsReplacedEvenIfTheCloudSaysOpen() async {
        let backend = FakeJoinBackend()
        await backend.setLifetime(-60)
        let model = make(backend)
        model.start()
        #expect(await wait(model) { $0 == .expired })
        #expect(await backend.created.count == 4)
    }

    @Test func closingCancelsTheTicketAndStopsLooking() async throws {
        let backend = FakeJoinBackend()
        let model = make(backend)
        model.start()
        #expect(await wait(model, isShowing))
        model.close()
        for _ in 0..<200 where await backend.cancelled.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await backend.cancelled == ["ticket-1"])
        let calls = await backend.statusCalls
        try await Task.sleep(for: .milliseconds(60))
        #expect(await backend.statusCalls <= calls + 1)
        // A second close and a late new code do nothing.
        model.close()
        model.newCode()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await backend.cancelled.count == 1)
        #expect(await backend.created.count == 1)
    }

    @Test func aNewCodeCancelsTheOldTicketFirst() async throws {
        let backend = FakeJoinBackend()
        let model = make(backend)
        model.start()
        #expect(await wait(model, isShowing))
        model.newCode()
        for _ in 0..<200 where await backend.created.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await backend.cancelled.first == "ticket-1")
        #expect(await backend.created.count == 2)
        model.close()
    }
}
