import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// What the wizard needs from a server. `ServerModel` conforms; the tests bring a fake.
@MainActor
protocol PhoneWizardServer: RelayHost {
    var wizardID: UUID { get }
    var wizardName: String { get }
    var isConnected: Bool { get }
    var canPair: Bool { get }
    func wizardPairCode() async throws -> PairCode
    func wizardDevices() async throws -> [Device]
}

extension ServerModel: PhoneWizardServer {
    var wizardID: UUID { id }
    var wizardName: String { info?.hostname ?? config.name }
    var isConnected: Bool { state == .connected }
    var canPair: Bool { supports("pairing") }
    func wizardPairCode() async throws -> PairCode { try await createPairCode() }
    func wizardDevices() async throws -> [Device] { try await devices() }
}

/// «Подключить iPhone»: picks the server, turns the cloud on (or takes the one that is on), shows the QR code and waits
/// for the phone to appear in the server's devices. No questions in between.
@MainActor
@Observable
final class ConnectPhoneModel {
    enum Problem: Equatable {
        /// No connected server can work through the cloud.
        case noServer
        case needsSignIn
        /// Words of the failure, ready to show.
        case message(UserFacingMessage)
    }

    enum Step: Equatable {
        case pickServer
        /// `detail` is what the cloud is doing: turning on, connecting.
        case preparing(detail: CloudAccessRules.Status)
        case scan(PhoneAccessRules.PairState)
        case done(device: String)
        case problem(Problem)
    }

    private(set) var step: Step
    private(set) var servers: [any PhoneWizardServer] = []
    private(set) var chosen: (any PhoneWizardServer)?
    @ObservationIgnored private let candidates: [any PhoneWizardServer]
    @ObservationIgnored private let makeController: @MainActor (any PhoneWizardServer) -> RelayController
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var controller: RelayController?
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var baseline: Set<String> = []

    init(
        candidates: [any PhoneWizardServer], pollInterval: Duration = .seconds(2),
        makeController: @escaping @MainActor (any PhoneWizardServer) -> RelayController
    ) {
        self.candidates = candidates
        self.pollInterval = pollInterval
        self.makeController = makeController
        step = .preparing(detail: .enabling)
    }

    /// The servers that can be used: connected, with the cloud and pairing in the daemon.
    static func eligible(_ servers: [any PhoneWizardServer]) -> [any PhoneWizardServer] {
        servers.filter { $0.isConnected && $0.supportsRelay && $0.canPair }
    }

    func start() {
        guard run == nil, chosen == nil else { return }
        servers = Self.eligible(candidates)
        switch servers.count {
        case 0: step = .problem(.noServer)
        case 1: choose(servers[0])
        default: step = .pickServer
        }
    }

    func choose(_ server: any PhoneWizardServer) {
        chosen = server
        begin()
    }

    /// Starts again with the chosen server (after a problem, or when the code ran out).
    func retry() {
        guard chosen != nil else { return start() }
        begin()
    }

    func cancel() {
        generation += 1
        run?.cancel()
        run = nil
    }

    /// A new code for the same phone: the baseline stays, so only a device that appeared after the start counts.
    func newCode() {
        guard let server = chosen else { return }
        generation += 1
        let mine = generation
        run?.cancel()
        run = Task { [weak self] in
            guard let self else { return }
            await self.showCode(server, mine)
        }
    }

    private func begin() {
        guard let server = chosen else { return }
        generation += 1
        let mine = generation
        run?.cancel()
        step = .preparing(detail: .enabling)
        let controller = makeController(server)
        self.controller = controller
        run = Task { [weak self] in
            guard let self else { return }
            // The wizard follows what the controller does, so the person sees "turning on", then "connecting".
            let watcher = Task { @MainActor [weak self, weak controller] in
                while !Task.isCancelled {
                    if let self, let controller, self.generation == mine, case .preparing = self.step {
                        let status = CloudAccessRules.status(
                            phase: controller.phase, relay: controller.status, problem: nil)
                        if status != .off, self.step != .preparing(detail: status) { self.step = .preparing(detail: status) }
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let ready = await controller.enable()
            watcher.cancel()
            guard self.generation == mine, !Task.isCancelled else { return }
            if !ready {
                self.step = .problem(Self.problem(for: controller))
                return
            }
            await self.showCode(server, mine)
        }
    }

    private func showCode(_ server: any PhoneWizardServer, _ mine: Int) async {
        do {
            if baseline.isEmpty, let known = try? await server.wizardDevices() { baseline = Set(known.map(\.id)) }
            let reply = try await server.wizardPairCode()
            guard generation == mine, !Task.isCancelled else { return }
            let state = PhoneAccessRules.pairState(for: reply)
            step = .scan(state)
            guard case .ready = state else { return }
            try await watch(server, mine, until: PhoneAccessRules.shownFor(reply))
        } catch {
            guard generation == mine, !Task.isCancelled else { return }
            step = .problem(.message(UserFacingError.message(for: error)))
        }
    }

    /// Looks at the server's devices until a new one shows up or the code's time is up.
    private func watch(_ server: any PhoneWizardServer, _ mine: Int, until lifetime: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + lifetime
        while clock.now < deadline {
            try await Task.sleep(for: pollInterval)
            guard generation == mine else { return }
            if let devices = try? await server.wizardDevices(), let fresh = devices.first(where: { !baseline.contains($0.id) }) {
                step = .done(device: fresh.name)
                return
            }
        }
        guard generation == mine else { return }
        step = .scan(.expired)
    }

    static func problem(for controller: RelayController) -> Problem {
        switch controller.problem {
        case .needsSignIn: return .needsSignIn
        case .unsupported: return .noServer
        case nil: return .message(UserFacingMessage(text: L10n.Failure.generic))
        case .some:
            switch CloudAccessRules.status(phase: .idle, relay: controller.status, problem: controller.problem) {
            case .failed(let message): return .message(message)
            case .tooMany: return .message(UserFacingMessage(text: L10n.ServerSettings.Phone.Cloud.tooMany))
            case .waiting(let reason):
                if let reason, !reason.isEmpty {
                    return .message(UserFacingMessage(text: L10n.ServerSettings.Phone.Cloud.waitingReason(reason: reason)))
                }
                return .message(UserFacingMessage(text: L10n.ServerSettings.Phone.Cloud.waiting))
            default: return .message(UserFacingMessage(text: L10n.Failure.generic))
            }
        }
    }
}
