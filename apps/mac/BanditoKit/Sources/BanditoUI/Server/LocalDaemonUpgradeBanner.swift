import BanditoDesign
import BanditoKit
import BanditoL10n
import Observation
import SwiftUI

/// What the upgrade needs from a server. `ServerModel` conforms; tests use a fake.
@MainActor
protocol LocalUpgradeServer: AnyObject {
    var serverID: UUID { get }
    /// This server is this Mac's daemon (see `LocalDaemonUpgrade.isThisMac`).
    var isThisMacServer: Bool { get }
    var isConnectedNow: Bool { get }
    /// Some agent is working or waits for the person.
    var hasBusyAgents: Bool { get }
    /// The daemon version the server reported last (`daemon.info`).
    var runningVersion: String? { get }
}

extension ServerModel: LocalUpgradeServer {
    var serverID: UUID { id }
    var isThisMacServer: Bool { LocalDaemonUpgrade.isThisMac(config) }
    var isConnectedNow: Bool { state == .connected }
    var hasBusyAgents: Bool { agents.contains { $0.status == .working || $0.status == .needsYou } }
    var runningVersion: String? { info?.version }
}

/// Upgrades this Mac's daemon to the one in the app bundle (see `LocalDaemonUpgrade`). It runs once per server and
/// launch, after the server has answered `daemon.info`. Agents are not interrupted: while one works or needs the
/// person, the upgrade waits for them, and the banner offers "Обновить сейчас" with a confirmation.
@MainActor
@Observable
final class LocalDaemonUpgradeModel {
    enum Phase: Equatable {
        case idle
        /// The upgrade is due, and agents are busy. It runs when they are free, or when the person confirms it.
        case waitingForAgents(serverID: UUID, version: String)
        /// The daemon is being replaced and restarts. The version is the bundled one.
        case upgrading(serverID: UUID, version: String)
        /// The replacement failed, the daemon did not come back on the new version, or the server is not connected.
        case failed(serverID: UUID, UserFacingMessage)

        /// The server this phase is about; nil when idle.
        var serverID: UUID? {
            switch self {
            case .idle: nil
            case .waitingForAgents(let id, _), .upgrading(let id, _), .failed(let id, _): id
            }
        }
    }

    private(set) var phase: Phase = .idle
    /// The daemon version in the app bundle, once it has been read. Nil when the bundle has no daemon.
    private(set) var bundled: String?
    /// True once the bundle has been read, even when it carries no daemon: until then `bundled` says nothing.
    private(set) var bundleRead = false

    @ObservationIgnored private let installer: any DaemonReplacing
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let returnTimeout: Duration
    @ObservationIgnored private let isQA: Bool
    /// A request is in progress. Set before the first suspension, so a second request at once is refused.
    @ObservationIgnored private var requesting = false
    /// Servers already upgraded (or attempted) in this launch: one attempt each. A waiting upgrade is not an attempt.
    @ObservationIgnored private var tried: Set<UUID> = []
    /// Servers whose waiting upgrade the person confirmed: it runs even while agents are busy.
    @ObservationIgnored private var confirmed: Set<UUID> = []
    /// The waiting job per server: it runs the upgrade once the server is connected and, unless confirmed, free.
    @ObservationIgnored private var waiting: [UUID: Task<Void, Never>] = [:]

    init(
        installer: any DaemonReplacing = LocalInstaller(runner: ProcessCommandRunner(), hostName: nil, fallbackName: ""),
        pollInterval: Duration = .seconds(3),
        returnTimeout: Duration = .seconds(120),
        isQA: Bool = QABuild.isRunningQA
    ) {
        self.installer = installer
        self.pollInterval = pollInterval
        self.returnTimeout = returnTimeout
        self.isQA = isQA
    }

    /// Whether the upgrade applies to this server now: this Mac's daemon, older than the bundle, and not a QA copy.
    func replacesOffer(for server: any LocalUpgradeServer) -> Bool {
        LocalDaemonUpgrade.decide(
            serverVersion: server.runningVersion, bundledVersion: bundled,
            isLocalServer: server.isThisMacServer, isQA: isQA)
    }

    /// Upgrades the server when it is due. With busy agents the upgrade waits for them, and no attempt is used up.
    func upgradeIfNeeded(_ server: any LocalUpgradeServer) async {
        // A QA copy is refused first: it does not even read the bundled daemon.
        guard !isQA, server.isThisMacServer else { return }
        let id = server.serverID
        guard server.isConnectedNow, !tried.contains(id), waiting[id] == nil else { return }
        bundled = await installer.bundledVersion()
        guard let target = bundled, replacesOffer(for: server) else { return }
        if server.hasBusyAgents {
            phase = .waitingForAgents(serverID: id, version: target)
            startWaiting(server)
            return
        }
        tried.insert(id)
        await perform(server, target: target)
    }

    /// Reads the bundled daemon version, so `replacesOffer` can answer on a page that opens before any upgrade ran.
    func readBundled() async {
        bundled = await installer.bundledVersion()
        bundleRead = true
    }

    /// The Updates page's word for this Mac's daemon. Reads the bundle when it has not been read yet.
    func standing(for server: any LocalUpgradeServer) -> LocalUpgradeStanding {
        LocalDaemonUpgrade.standing(
            bundleRead: bundleRead, bundledVersion: bundled, serverVersion: server.runningVersion,
            isLocalServer: server.isThisMacServer, isQA: isQA)
    }

    /// The person asks for the upgrade now (Server or Settings → Updates). Same rules as the automatic upgrade, but
    /// it is not limited to one attempt per launch: a failed upgrade can be asked for again. Busy agents make it wait
    /// for the person's confirmation, as the banner says.
    func upgradeByRequest(_ server: any LocalUpgradeServer) async {
        guard !isQA, server.isThisMacServer, server.isConnectedNow, !requesting else { return }
        if case .upgrading = phase { return }
        requesting = true
        defer { requesting = false }
        await readBundled()
        guard let target = bundled, replacesOffer(for: server) else { return }
        let id = server.serverID
        tried.remove(id)
        cancelWaiting(id)
        if server.hasBusyAgents {
            phase = .waitingForAgents(serverID: id, version: target)
            startWaiting(server)
            return
        }
        tried.insert(id)
        await perform(server, target: target)
    }

    /// Runs the waiting upgrade now, while agents work: the person confirmed that they will be interrupted.
    /// A server that is not connected cannot be upgraded yet: the message says so, and the upgrade runs on connect.
    func updateNow(_ server: any LocalUpgradeServer) async {
        guard case .waitingForAgents = phase else { return }
        let id = server.serverID
        confirmed.insert(id)
        if server.isConnectedNow {
            cancelWaiting(id)
            await runWhenFree(server)
        } else {
            phase = .failed(serverID: id, Self.notConnected)
            startWaiting(server)
        }
    }

    /// Tries a failed upgrade again. On a server that is not connected, the phase stays a failure with the
    /// "not connected" message, and the upgrade runs once the server connects.
    func retry(_ server: any LocalUpgradeServer) async {
        guard case .failed = phase else { return }
        let id = server.serverID
        tried.remove(id)
        guard server.isConnectedNow else {
            phase = .failed(serverID: id, Self.notConnected)
            startWaiting(server)
            return
        }
        cancelWaiting(id)
        phase = .idle
        await upgradeIfNeeded(server)
    }

    /// The server is removed or replaced by another model: its waiting upgrade ends, and a new model of it starts
    /// afresh. A running upgrade is not stopped; it finishes on its own.
    func forget(serverID id: UUID) {
        cancelWaiting(id)
        confirmed.remove(id)
        tried.remove(id)
        if phase.serverID == id, !isRunning(phase) { phase = .idle }
    }

    private func isRunning(_ phase: Phase) -> Bool {
        if case .upgrading = phase { return true }
        return false
    }

    private static var notConnected: UserFacingMessage {
        UserFacingMessage(text: L10n.Server.LocalUpgrade.notConnected, canRetry: true)
    }

    private func startWaiting(_ server: any LocalUpgradeServer) {
        let id = server.serverID
        guard waiting[id] == nil else { return }
        waiting[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if server.isConnectedNow {
                    if confirmed.contains(id) || !server.hasBusyAgents {
                        waiting[id] = nil
                        await self.runWhenFree(server)
                        return
                    }
                    // Connected again with agents still busy: the banner shows the wait, not the old failure.
                    if let target = bundled, case .failed(let failedID, _) = phase, failedID == id {
                        phase = .waitingForAgents(serverID: id, version: target)
                    }
                }
                do {
                    try await Task.sleep(for: self.pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        waiting[id]?.cancel()
        waiting[id] = nil
    }

    /// The waiting job's last step: the upgrade runs if it is still due and not tried; otherwise a wait ends quietly.
    private func runWhenFree(_ server: any LocalUpgradeServer) async {
        let id = server.serverID
        confirmed.remove(id)
        guard !tried.contains(id), let target = bundled, replacesOffer(for: server) else {
            if case .waitingForAgents = phase { phase = .idle }
            return
        }
        tried.insert(id)
        await perform(server, target: target)
    }

    private func perform(_ server: any LocalUpgradeServer, target: String) async {
        let id = server.serverID
        // The wait is over once the upgrade runs. The waiting job is already gone when it calls this.
        cancelWaiting(id)
        phase = .upgrading(serverID: id, version: target)
        do {
            try await installer.upgrade()
            // The link drops while the daemon restarts; the reconnect reads `daemon.info` again.
            let deadline = ContinuousClock.now.advanced(by: returnTimeout)
            while ContinuousClock.now < deadline {
                if server.isConnectedNow, server.runningVersion == target {
                    phase = .idle
                    return
                }
                try await Task.sleep(for: pollInterval)
            }
            phase = .failed(
                serverID: id, UserFacingMessage(text: L10n.Server.LocalUpgrade.timedOut(version: target), canRetry: true))
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(
                serverID: id, UserFacingError.message(for: error).wrapped { L10n.Server.LocalUpgrade.failed(error: $0) })
        }
    }
}

/// Server → Overview: the upgrade of this Mac's daemon, waiting for agents, running, or failed. The banner that waits
/// has the button "Обновить сейчас", which asks first, because the agents would be interrupted. It shows only on
/// this Mac's own server, and only for an upgrade that is about it.
struct LocalDaemonUpgradeBanner: View {
    let server: ServerModel
    let model: LocalDaemonUpgradeModel
    @State private var confirming = false

    var body: some View {
        let shown = server.isThisMacServer && model.phase.serverID == server.serverID ? model.phase : .idle
        switch shown {
        case .idle:
            EmptyView()
        case .waitingForAgents:
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Bandito.signal)
                Text(L10n.Server.LocalUpgrade.waiting)
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 8)
                Button(L10n.Server.LocalUpgrade.updateNow) { confirming = true }
                    .banditoButton(.lightPill())
            }
            .banner()
            .confirmationDialog(
                L10n.Server.LocalUpgrade.confirmTitle, isPresented: $confirming, titleVisibility: .visible
            ) {
                Button(L10n.Server.LocalUpgrade.confirm) {
                    Task { await model.updateNow(server) }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            }
        case .upgrading(_, let version):
            HStack(alignment: .center, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.Server.LocalUpgrade.title(version: version))
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 8)
            }
            .banner()
        case .failed(_, let failure):
            VStack(alignment: .leading, spacing: 10) {
                UserFacingErrorView(message: failure)
                if failure.canRetry {
                    HStack {
                        Spacer(minLength: 0)
                        Button(L10n.Server.LocalUpgrade.retry) {
                            Task { await model.retry(server) }
                        }
                        .banditoButton(.lightPill())
                    }
                }
            }
            .banner()
        }
    }
}

private extension View {
    /// The same card as the daemon update banner: a signal tint, one padding, one corner radius.
    func banner() -> some View {
        padding(14)
            .background(Color.Bandito.signal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.Bandito.signal.opacity(0.28), lineWidth: 1))
    }
}
