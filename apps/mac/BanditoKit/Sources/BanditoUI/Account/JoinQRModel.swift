import BanditoKit
import BanditoL10n
import CryptoKit
import Foundation
import Observation

/// What the join sheet needs from the account service. `AccountClient` conforms; the tests bring a fake.
protocol JoinQRBackend: Sendable {
    func createTicket(hash: String) async throws -> (id: String, expiresAt: Date)
    func ticketStatus(id: String) async throws -> TicketStatus
    func cancelTicket(id: String) async throws
    func approve(_ device: PendingDevice, confirmedFingerprint: String, syncKey: SymmetricKey) async throws
    func deleteDevice(id: String, force: Bool) async throws
}

/// The account service with this Mac's keys: what the sheet really talks to.
struct AccountJoinBackend: JoinQRBackend {
    let client: AccountClient
    let identity: DeviceIdentity

    func createTicket(hash: String) async throws -> (id: String, expiresAt: Date) {
        try await client.createTicket(hash: hash)
    }

    func ticketStatus(id: String) async throws -> TicketStatus {
        try await client.ticketStatus(id: id)
    }

    func cancelTicket(id: String) async throws {
        try await client.cancelTicket(id: id)
    }

    func approve(_ device: PendingDevice, confirmedFingerprint: String, syncKey: SymmetricKey) async throws {
        try await client.approve(device, confirmedFingerprint: confirmedFingerprint, syncKey: syncKey, identity: identity)
    }

    func deleteDevice(id: String, force: Bool) async throws {
        try await client.deleteDevice(id: id, force: force)
    }
}

/// Why this Mac cannot show a code, and what to do about it.
enum JoinQRBlocker: Equatable, Sendable {
    case signedOut
    /// Another device has to approve this Mac first.
    case notApproved
    /// This Mac is in the account but holds no sync key to hand over.
    case noSyncKey
}

/// «Войти с помощью Mac», the Mac's side: makes a join ticket, shows it as a QR code, watches it, and when the iPhone
/// has scanned it checks the iPhone's proof and lets it in (the sync key is sealed to the iPhone's key, no code is typed).
///
/// One ticket is shown at a time. A ticket that runs out is replaced by a new one, at most `maxRenewals` times in a
/// row; then the sheet offers a button. Closing the sheet cancels the ticket (silently).
@MainActor
@Observable
final class JoinQRModel {
    enum Phase: Equatable {
        /// The ticket is being made.
        case preparing
        /// This Mac cannot show a code.
        case blocked(JoinQRBlocker)
        /// The code is on screen until `expiresAt`.
        case showing(link: String, expiresAt: Date)
        /// The iPhone scanned the code and is signing in. `name` is known once the cloud has its device. `retrying` is
        /// set while an approval that did not get through is repeated.
        case claiming(name: String?, retrying: Bool)
        /// The iPhone is in: its servers follow within seconds.
        case added(name: String)
        /// The ticket could not be made, or the approval failed for good.
        case failed(UserFacingMessage)
        /// The proof did not match: the device was removed (`removed`) or the removal failed.
        case badProof(removed: Bool)
        /// The code ran out and the automatic new ones are used up: the person asks for the next one.
        case expired
    }

    /// How many times in a row a code that ran out is replaced without a click.
    static let maxRenewals = 3

    private(set) var phase: Phase = .preparing

    @ObservationIgnored private let backend: JoinQRBackend
    @ObservationIgnored private let macPublicKey: Curve25519.KeyAgreement.PublicKey
    @ObservationIgnored private let macName: String
    @ObservationIgnored private let blocker: @MainActor () async -> JoinQRBlocker?
    @ObservationIgnored private let syncKey: @MainActor () -> SymmetricKey?
    @ObservationIgnored private let onApproved: @MainActor () async -> Void
    @ObservationIgnored private let onFinished: @MainActor () -> Void
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let finishDelay: Duration

    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var finishing: Task<Void, Never>?
    /// The ticket that is on screen (its id, for the cancel).
    @ObservationIgnored private var currentID: String?
    @ObservationIgnored private var closed = false
    /// Counts runs: a stale run (a new code was asked for) stops writing the phase.
    @ObservationIgnored private var generation = 0
    /// How many tickets were made (tests).
    @ObservationIgnored private(set) var ticketsMade = 0

    init(
        backend: JoinQRBackend, macPublicKey: Curve25519.KeyAgreement.PublicKey, macName: String,
        blocker: @escaping @MainActor () async -> JoinQRBlocker?,
        syncKey: @escaping @MainActor () -> SymmetricKey?,
        onApproved: @escaping @MainActor () async -> Void = {},
        onFinished: @escaping @MainActor () -> Void = {},
        pollInterval: Duration = .seconds(2), finishDelay: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.backend = backend
        self.macPublicKey = macPublicKey
        self.macName = macName
        self.blocker = blocker
        self.syncKey = syncKey
        self.onApproved = onApproved
        self.onFinished = onFinished
        self.pollInterval = pollInterval
        self.finishDelay = finishDelay
        self.sleep = sleep
        self.now = now
    }

    /// A model that shows a given phase and does nothing (the layout audit and the screenshots).
    static func preview(_ phase: Phase) -> JoinQRModel {
        let model = JoinQRModel(
            backend: IdleJoinBackend(),
            macPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey, macName: "Mac",
            blocker: { nil }, syncKey: { nil })
        model.phase = phase
        model.closed = true
        return model
    }

    // MARK: Control

    /// Starts the first code. Calling it again does nothing.
    func start() {
        guard run == nil, !closed else { return }
        launch(renewals: 0)
    }

    /// The person asked for a new code (after it ran out or failed): the old ticket is cancelled and a new one is made.
    func newCode() {
        guard !closed else { return }
        cancelCurrentTicket()
        launch(renewals: 0)
    }

    /// The sheet closed: the polling stops and the ticket is cancelled, silently. Safe to call twice.
    func close() {
        guard !closed else { return }
        closed = true
        generation += 1
        run?.cancel()
        run = nil
        finishing?.cancel()
        finishing = nil
        cancelCurrentTicket()
    }

    private func launch(renewals: Int) {
        generation += 1
        let mine = generation
        run?.cancel()
        phase = .preparing
        run = Task { [weak self] in
            await self?.loop(mine, renewals: renewals)
        }
    }

    private func isCurrent(_ mine: Int) -> Bool {
        generation == mine && !closed && !Task.isCancelled
    }

    /// Cancels the ticket on screen. An error is ignored: the ticket ends by itself.
    private func cancelCurrentTicket() {
        guard let id = currentID else { return }
        currentID = nil
        let backend = backend
        Task { try? await backend.cancelTicket(id: id) }
    }

    // MARK: The run

    private func loop(_ mine: Int, renewals start: Int) async {
        if let reason = await blocker() {
            guard isCurrent(mine) else { return }
            phase = .blocked(reason)
            return
        }
        guard isCurrent(mine) else { return }
        var renewals = start
        while isCurrent(mine) {
            let ticket = JoinTicket.make(macPublicKey: macPublicKey, macName: macName)
            let created: (id: String, expiresAt: Date)
            do {
                created = try await backend.createTicket(hash: ticket.ticketHash)
            } catch {
                guard isCurrent(mine) else { return }
                phase = .failed(SignInMessages.text(for: error))
                return
            }
            ticketsMade += 1
            guard isCurrent(mine) else {
                // Closed or replaced while the ticket was being made: it is not shown, so it is taken back.
                let backend = backend
                Task { try? await backend.cancelTicket(id: created.id) }
                return
            }
            currentID = created.id
            phase = .showing(link: ticket.link.absoluteString, expiresAt: created.expiresAt)
            switch await watch(ticket, id: created.id, expiresAt: created.expiresAt, mine) {
            case .done:
                return
            case .expired:
                guard isCurrent(mine) else { return }
                if renewals >= Self.maxRenewals {
                    phase = .expired
                    return
                }
                renewals += 1
            }
        }
    }

    private enum Outcome {
        case done
        case expired
    }

    /// Looks at the ticket every `pollInterval` until it ends. An error of the network is not the end.
    private func watch(_ ticket: JoinTicket, id: String, expiresAt: Date, _ mine: Int) async -> Outcome {
        // A device that claimed the ticket is handled until its answer is final, whatever the clock says.
        var claimed = false
        while isCurrent(mine) {
            do {
                try await sleep(pollInterval)
            } catch {
                return .done
            }
            guard isCurrent(mine) else { return .done }
            do {
                switch try await backend.ticketStatus(id: id) {
                case .open:
                    if !claimed, now() >= expiresAt.addingTimeInterval(5) { return .expired }
                case .expired:
                    if !claimed { return .expired }
                    // The device signed in but the approval never got through before the ticket ended.
                    phase = .failed(UserFacingMessage(text: L10n.Onboarding.Account.errorGeneric))
                    return .done
                case .claiming:
                    // Spent, no device attached yet. If the sign-in fails on the cloud's side the ticket turns `expired`
                    // after 30 seconds and a new code is made.
                    if case .claiming = phase {} else { phase = .claiming(name: nil, retrying: false) }
                case .claimed(let device, let proof):
                    claimed = true
                    if await admit(device, proof: proof, ticket: ticket, mine) { return .done }
                }
            } catch is CancellationError {
                return .done
            } catch where Self.isTransient(error) {
                // No answer this time (the network, a gateway): the next look tries again. A ticket that ran out while the
                // cloud was out of reach is replaced.
                if !claimed, now() >= expiresAt.addingTimeInterval(5) { return .expired }
            } catch AccountError.api(let code, _) where code == "not_found" && !claimed {
                // The cloud no longer has the ticket (it was swept after it ran out).
                return .expired
            } catch {
                guard isCurrent(mine) else { return .done }
                phase = .failed(SignInMessages.text(for: error))
                return .done
            }
        }
        return .done
    }

    /// The iPhone redeemed the ticket. Returns true when the run is over (it was let in, it was refused, or the failure
    /// is final); false when the approval did not get through and the next look repeats it.
    private func admit(_ device: ClaimedDevice, proof: String, ticket: JoinTicket, _ mine: Int) async -> Bool {
        guard JoinProof.verify(proof, macKey: ticket.macKey, publicKey: device.publicKey, signingKey: device.signingKey)
        else {
            await refuse(device, mine)
            return true
        }
        guard isCurrent(mine) else { return true }
        guard let key = syncKey(), let code = try? DeviceFingerprint.code(publicKeyBase64: device.publicKey) else {
            phase = .failed(UserFacingMessage(text: L10n.JoinQR.Blocked.noKey))
            return true
        }
        phase = .claiming(name: device.name, retrying: false)
        let pending = PendingDevice(
            id: device.id, name: device.name, platform: device.platform, publicKey: device.publicKey, createdAt: "")
        do {
            try await backend.approve(pending, confirmedFingerprint: code, syncKey: key)
        } catch is CancellationError {
            return true
        } catch AccountError.api(let reason, _) where reason == "already_approved" {
            // The device is in already (an earlier try got through after all): the proof was checked, so it stays.
        } catch where Self.isTransient(error) {
            guard isCurrent(mine) else { return true }
            phase = .claiming(name: device.name, retrying: true)
            return false
        } catch {
            guard isCurrent(mine) else { return true }
            phase = .failed(SignInMessages.text(for: error))
            return true
        }
        guard isCurrent(mine) else { return true }
        phase = .added(name: device.name)
        scheduleFinish()
        await onApproved()
        return true
    }

    /// The proof did not match: nobody who saw this code made the request. The device is removed, even if the sheet is
    /// closed meanwhile (the removal is its own task, a cancel does not cut it).
    private func refuse(_ device: ClaimedDevice, _ mine: Int) async {
        let backend = backend
        let id = device.id
        let removed = await Task { (try? await backend.deleteDevice(id: id, force: false)) != nil }.value
        guard isCurrent(mine) else { return }
        phase = .badProof(removed: removed)
    }

    /// The sheet closes by itself a moment after "added".
    private func scheduleFinish() {
        finishing?.cancel()
        let delay = finishDelay
        let sleep = sleep
        finishing = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !self.closed else { return }
            self.onFinished()
        }
    }

    /// A failure that the next look may not repeat: no network, or a gateway or server error.
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case AccountError.network: true
        case AccountError.api(let code, _): code == "server" || code.hasPrefix("http_5")
        default: false
        }
    }
}

/// A backend that is never called (the preview model).
private struct IdleJoinBackend: JoinQRBackend {
    func createTicket(hash: String) async throws -> (id: String, expiresAt: Date) { throw AccountError.badResponse }
    func ticketStatus(id: String) async throws -> TicketStatus { throw AccountError.badResponse }
    func cancelTicket(id: String) async throws {}
    func approve(_ device: PendingDevice, confirmedFingerprint: String, syncKey: SymmetricKey) async throws {}
    func deleteDevice(id: String, force: Bool) async throws {}
}
