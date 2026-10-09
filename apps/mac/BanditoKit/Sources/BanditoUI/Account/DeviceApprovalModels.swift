import BanditoKit
import BanditoL10n
import CryptoKit
import Foundation
import Observation

/// Something this Mac cannot do because it has no sync key.
enum DeviceApprovalError: Error, Equatable, LocalizedError {
    case noSyncKey

    var errorDescription: String? {
        L10n.Onboarding.Account.noKeyHere
    }
}

/// The new device's side: it shows its own code and waits for another device to hand over the sync key.
/// When the envelope arrives, the sender's code is shown, and the user confirms it matches the other screen.
@MainActor
@Observable
final class DeviceApprovalModel {
    enum Phase: Equatable {
        case waiting
        /// The envelope opened. `senderCode` is the approving device's code, to compare with its screen.
        case confirmSender(senderCode: String)
        /// The codes did not match: the key was dropped.
        case rejected
        case failed(String)
        case finished
    }

    private(set) var phase: Phase = .waiting
    /// How many times the server was asked for the envelope.
    private(set) var polls = 0
    let ownFingerprint: String

    @ObservationIgnored private var pending: PendingSyncKey?
    @ObservationIgnored private let backend: DeviceApprovalBackend
    @ObservationIgnored private let identity: DeviceIdentity
    @ObservationIgnored private let accountID: String
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let keys: SecretStore
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(
        backend: DeviceApprovalBackend, identity: DeviceIdentity, accountID: String, deviceID: String,
        keys: SecretStore, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.backend = backend
        self.identity = identity
        self.accountID = accountID
        self.deviceID = deviceID
        self.keys = keys
        self.sleep = sleep
        ownFingerprint = identity.fingerprint
    }

    /// One look at the server. Returns true when the wait is over (an envelope arrived, or polling failed for good).
    /// A network error is not the end: the next look tries again.
    func pollOnce() async -> Bool {
        polls += 1
        do {
            guard let envelope = try await backend.myEnvelope() else { return false }
            let opened = try SyncKey.open(
                envelope: envelope.envelope, with: identity, accountID: accountID, deviceID: deviceID)
            pending = opened
            phase = .confirmSender(senderCode: opened.senderFingerprint)
            return true
        } catch is CancellationError {
            // Leaving the screen is not a failure: the poll just stops.
            return false
        } catch AccountError.network {
            return false
        } catch {
            if Task.isCancelled { return false }
            phase = .failed(SignInMessages.text(for: error))
            return true
        }
    }

    /// Polls every three seconds until the wait is over or the task is cancelled (leaving the screen).
    func runPolling() async {
        while !Task.isCancelled, phase == .waiting {
            if await pollOnce() { return }
            do {
                try await sleep(.seconds(3))
            } catch {
                return
            }
        }
    }

    /// The user compared the sender's code with the other device: the sync key is kept.
    func confirmSender() throws {
        guard let pending, case .confirmSender(let code) = phase else { return }
        let key = try pending.accept(confirmedFingerprint: code)
        try SyncKey.save(key, to: keys)
        self.pending = nil
        phase = .finished
    }

    /// The codes differ: the key is dropped and nothing is stored. The device is removed from the account too:
    /// the other side is not this device, so this device has no reason to stay. Returns whether the server removed it.
    func refuse() async -> Bool {
        pending = nil
        phase = .rejected
        do {
            try await backend.deleteDevice(id: deviceID, force: false)
            return true
        } catch {
            return false
        }
    }
}

/// The approving side: a device waiting for approval is shown, its code is typed in, and this device sends the key.
/// The codes are compared here first. A mismatch never reaches the server.
@MainActor
@Observable
final class ApproveDeviceModel {
    let device: PendingDevice
    let ownFingerprint: String

    private(set) var code = DeviceCodeInput()
    private(set) var errorText: String?
    private(set) var isBusy = false
    private(set) var approved = false

    @ObservationIgnored private let backend: DeviceApprovalBackend
    @ObservationIgnored private let identity: DeviceIdentity
    @ObservationIgnored private let syncKey: () throws -> SymmetricKey

    init(
        device: PendingDevice, backend: DeviceApprovalBackend, identity: DeviceIdentity,
        syncKey: @escaping () throws -> SymmetricKey
    ) {
        self.device = device
        self.backend = backend
        self.identity = identity
        self.syncKey = syncKey
        ownFingerprint = identity.fingerprint
    }

    var canApprove: Bool {
        code.isComplete && !isBusy && !approved
    }

    func enter(_ text: String) {
        code.enter(text)
        errorText = nil
    }

    /// Sends the sync key to the device if the typed code is the device's own code.
    func approve() async {
        guard canApprove else { return }
        guard let computed = try? DeviceFingerprint.code(publicKeyBase64: device.publicKey),
            DeviceFingerprint.matches(computed, code.raw)
        else {
            errorText = L10n.Onboarding.Account.codeMismatch
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let key = try syncKey()
            try await backend.approve(device, confirmedFingerprint: code.raw, syncKey: key, identity: identity)
            approved = true
        } catch AccountError.fingerprintMismatch {
            errorText = L10n.Onboarding.Account.codeMismatch
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }

    /// Refuses the device: it is removed from the account. Returns true when the server removed it.
    func reject() async -> Bool {
        do {
            try await backend.deleteDevice(id: device.id, force: false)
            return true
        } catch {
            errorText = SignInMessages.text(for: error)
            return false
        }
    }
}
