import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// A sign-in to a service with a code (docs/ARCHITECTURE.md#integrations, feature `integrations_device`). The daemon
/// asks the provider for the code and polls for the token; this starts it, shows the code, opens the provider's page
/// when asked and reads the flow's state until it ends. One sign-in is in progress at a time. Nothing goes to the
/// pasteboard or the browser by itself.
@MainActor
@Observable
public final class DeviceSignIn {
    public enum Phase: Equatable {
        case idle
        /// Asking the server for a code.
        case starting(name: String)
        /// The code is on screen; the owner types it on the provider's page.
        case waiting(name: String, code: String, page: DevicePage, expiresAt: Date)
        case connected(name: String, integrationID: String)
        case failed(name: String, message: UserFacingMessage, canRetry: Bool)
    }

    public private(set) var phase: Phase = .idle {
        didSet { countOutcome(previous: oldValue) }
    }
    /// The code was put on the pasteboard (by Copy, or by Open); shown as a short note.
    public private(set) var copied = false

    @ObservationIgnored private let copyToPasteboard: @MainActor (String) -> Void
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let pollEvery: Duration
    /// What to start again for "Try again", and the server to tell when the owner gives up.
    @ObservationIgnored private var attempt: (server: any DeviceServer, target: DeviceBeginTarget, name: String, connectRequestId: String?, catalogID: String?)?
    @ObservationIgnored private var flowId: String?
    @ObservationIgnored private var poller: Task<Void, Never>?
    /// Changes with each start and each cancel, so an answer that arrives late knows it is out of date.
    @ObservationIgnored private var run = UUID()

    /// Status reads in a row that may fail (the server restarted, the link dropped) before the sign-in is given up.
    static let maxReadFailures = 5

    public init(
        pollEvery: Duration = .seconds(2),
        copyToPasteboard: @escaping @MainActor (String) -> Void = SystemActions.copy,
        openURL: @escaping @MainActor (URL) -> Void = SystemActions.open,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.pollEvery = pollEvery
        self.copyToPasteboard = copyToPasteboard
        self.openURL = openURL
        self.sleep = sleep
    }

    /// Whether a sheet should be on screen.
    public var isActive: Bool { phase != .idle }

    // MARK: - start

    /// Starts a sign-in: asks the server for a code and waits for the owner to confirm it. One that was waiting is
    /// given up first.
    ///
    /// With `connectRequestId` the sign-in answers an agent's request: when it ends well the daemon tells the agent.
    public func begin(
        server: any DeviceServer, target: DeviceBeginTarget, name: String, connectRequestId: String? = nil,
        catalogID: String? = nil
    ) async {
        await discard()
        let id = UUID()
        run = id
        attempt = (server, target, name, connectRequestId, catalogID)
        copied = false
        phase = .starting(name: name)
        do {
            let begun = try await server.deviceBegin(target, connectRequestId: connectRequestId)
            guard run == id else {
                // Cancelled while the server was answering.
                await server.deviceCancel(flowId: begun.flowId)
                return
            }
            guard let page = DevicePage(begun.verificationUri) else {
                await server.deviceCancel(flowId: begun.flowId)
                phase = .failed(name: name, message: Self.failure(nil), canRetry: true)
                return
            }
            flowId = begun.flowId
            let expires = Date(timeIntervalSince1970: Double(begun.expiresAt) / 1000)
            phase = .waiting(name: name, code: begun.userCode, page: page, expiresAt: expires)
            poller = Task { [weak self] in
                await self?.poll(run: id, server: server, flowId: begun.flowId, name: name)
            }
        } catch {
            guard run == id else { return }
            phase = .failed(name: name, message: Self.failure(error), canRetry: true)
        }
    }

    /// "Try again" after a failure: a new code from the start.
    public func retry() async {
        guard case .failed = phase, let attempt else { return }
        await begin(
            server: attempt.server, target: attempt.target, name: attempt.name,
            connectRequestId: attempt.connectRequestId, catalogID: attempt.catalogID)
    }

    /// Counts the end of a sign-in that started from a catalog template, once: connected is `ok`, failed is `fail`.
    private func countOutcome(previous: Phase) {
        guard !previous.isSettled, let catalogID = attempt?.catalogID, let counter = CatalogCounterID(catalogID) else {
            return
        }
        switch phase {
        case .connected: Telemetry.count(.integration(counter, ok: true))
        case .failed: Telemetry.count(.integration(counter, ok: false))
        default: return
        }
    }

    // MARK: - the code

    /// "Copy": the code goes to the pasteboard.
    public func copyCode() {
        guard case .waiting(_, let code, _, _) = phase else { return }
        copyToPasteboard(code)
        copied = true
    }

    /// "Open …": the code goes to the pasteboard and the provider's page opens, so the owner can paste it there.
    public func openPage() {
        guard case .waiting(_, let code, let page, _) = phase else { return }
        copyToPasteboard(code)
        copied = true
        openURL(page.url)
    }

    // MARK: - end

    /// The owner closes the sheet: a sign-in in progress is given up (the server is told), anything else just goes.
    public func dismiss() async {
        await discard()
        phase = .idle
    }

    /// Gives up a sign-in that is starting or waiting. The server is told so the flow ends at once.
    private func discard() async {
        run = UUID()
        poller?.cancel()
        poller = nil
        let id = flowId
        flowId = nil
        copied = false
        switch phase {
        case .starting, .waiting: phase = .idle
        default: break
        }
        if let id, let server = attempt?.server { await server.deviceCancel(flowId: id) }
    }

    // MARK: - polling

    /// Reads the flow's state until it ends. The daemon polls the provider; this only asks the daemon.
    private func poll(run id: UUID, server: any DeviceServer, flowId: String, name: String) async {
        var failures = 0
        while !Task.isCancelled {
            do { try await sleep(pollEvery) } catch { return }
            guard run == id else { return }
            do {
                let status = try await server.deviceStatus(flowId: flowId)
                guard run == id else { return }
                failures = 0
                if apply(status.state, name: name) { return }
            } catch {
                guard run == id else { return }
                failures += 1
                if failures >= Self.maxReadFailures {
                    self.flowId = nil
                    phase = .failed(name: name, message: Self.failure(error), canRetry: true)
                    return
                }
            }
        }
    }

    /// Takes the flow's state; returns whether it was the last one.
    private func apply(_ state: DeviceFlowState, name: String) -> Bool {
        switch state {
        case .pending:
            return false
        case .done(let integrationID, _, _):
            flowId = nil
            phase = .connected(name: name, integrationID: integrationID)
        case .failed(let reason, let detail):
            flowId = nil
            phase = .failed(name: name, message: Self.message(for: reason, detail: detail, name: name), canRetry: true)
        case .cancelled:
            // Ended on the server side (another start for the same service, or a disconnect).
            flowId = nil
            phase = .idle
        }
        return true
    }

    // MARK: - words

    /// A failed flow in words: the sentence is ours, what the daemon said goes under "Details".
    static func message(for reason: DeviceFailure, detail: String?, name: String) -> UserFacingMessage {
        switch reason {
        case .expired: UserFacingMessage(text: L10n.Integrations.Device.expired, canRetry: true)
        case .denied: UserFacingMessage(text: L10n.Integrations.Oauth.denied(name: name), canRetry: true)
        case .network: UserFacingMessage(text: L10n.Integrations.Device.network, technical: detail, canRetry: true)
        case .refused: UserFacingMessage(text: L10n.Integrations.Device.refused, technical: detail, canRetry: true)
        case .store, .other: UserFacingMessage(text: L10n.Integrations.Oauth.failed, technical: detail, canRetry: true)
        }
    }

    private static func failure(_ error: Error?) -> UserFacingMessage {
        guard let error else { return UserFacingMessage(text: L10n.Integrations.Oauth.failed, canRetry: true) }
        let message = UserFacingError.message(for: error)
        // A known failure (no answer from the server, a revoked device) keeps its own words; anything else gets ours,
        // with what the daemon said under the details.
        guard message.technical != nil else { return message }
        return UserFacingMessage(text: L10n.Integrations.Oauth.failed, technical: message.technical, canRetry: true)
    }
}

extension DeviceSignIn.Phase {
    /// Connected or failed: the sign-in is over.
    var isSettled: Bool {
        switch self {
        case .connected, .failed: true
        default: false
        }
    }
}
