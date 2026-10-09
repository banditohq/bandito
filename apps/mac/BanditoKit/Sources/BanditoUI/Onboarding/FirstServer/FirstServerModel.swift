import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// Step 3 of 5: where the team lives. "This Mac" runs `LocalInstaller`; "your own server" runs `SSHInstaller`.
/// Both feed the same `InstallChecklist`. On success the server is added to the app (and pushed to the account
/// when signed in), and the components of the server are shown from `SetupModel`.
@MainActor
@Observable
final class FirstServerModel {
    enum Option: Equatable {
        case thisMac
        case ownServer
    }

    enum Phase {
        case choosing
        case installing
        /// The host is new to this Mac: its fingerprint is shown, and nothing is trusted until the person says so.
        case reviewingHost(HostKeyPreview)
        case failed
        case connected(ServerConfig)
    }

    private(set) var option: Option?
    private(set) var phase: Phase = .choosing
    private(set) var checklist = InstallChecklist()
    /// The address as typed (`user@host[:port]`).
    var address = ""
    private(set) var addressError: String?
    private(set) var hostKeyError: String?
    /// For an address behind a jump host: the command to run once in Terminal, to confirm the key there.
    private(set) var proxyCommand: String?
    /// For a host whose old key is still in known_hosts: the command that removes that entry.
    private(set) var knownHostCommand: String?
    /// Known hosts from `~/.ssh/config` and `known_hosts`, shown as chips.
    private(set) var suggestions: [String] = []
    /// The components of the connected server.
    let setup = SetupModel()
    /// Set by the screen. Signed in, a new server is pushed to the account's sync blob.
    @ObservationIgnored var accountHub: AccountHub?

    @ObservationIgnored private let runner: CommandRunner
    @ObservationIgnored private let devBinary: URL?
    @ObservationIgnored private let devArchive: URL?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// Why the servers could not be published to the account, if they could not.
    private(set) var syncError: String?

    /// - Parameters:
    ///   - runner: runs ssh, scp and the local install (tests pass a fake).
    ///   - devBinary: a Linux build of bandito for development (`BANDITO_DEV_LINUX_BINARY`, Debug only).
    ///   - devArchive: a release archive for development (`BANDITO_DEV_ARCHIVE`, Debug only).
    init(
        runner: CommandRunner = ProcessCommandRunner(),
        devBinary: URL? = FirstServerModel.debugLinuxBinary,
        devArchive: URL? = FirstServerModel.debugReleaseArchive
    ) {
        self.runner = runner
        self.devBinary = devBinary
        self.devArchive = devArchive
    }

    /// In Debug builds, `BANDITO_DEV_LINUX_BINARY` names a Linux bandito to copy to the server (no release yet).
    /// Release builds never read it: they use the install script bundled in the app.
    static var debugLinuxBinary: URL? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["BANDITO_DEV_LINUX_BINARY"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
        #else
        return nil
        #endif
    }

    /// In Debug builds, `BANDITO_DEV_ARCHIVE` names a local release archive to install, before a release is published.
    /// It skips the download and the signature check. Release builds never read it.
    static var debugReleaseArchive: URL? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["BANDITO_DEV_ARCHIVE"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
        #else
        return nil
        #endif
    }

    /// The version of this app, which the server's release must match (`CFBundleShortVersionString`).
    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Hosts the person already uses: from their ssh config and known_hosts.
    func loadSuggestions(config: String, knownHosts: String) {
        suggestions = SSHConfigReader.suggestions(config: config, knownHosts: knownHosts)
    }

    func choose(_ option: Option) {
        self.option = option
    }

    /// "This Mac": copies bandito into `~/.local/bin` and starts the service.
    func startThisMac(app: AppModel) {
        option = .thisMac
        checklist.reset()
        phase = .installing
        let installer = LocalInstaller(runner: runner)
        run(installer.install(), app: app)
    }

    /// Own server: validates the address first, then installs over ssh (BatchMode, so no password prompt).
    func startOwnServer(app: AppModel) {
        option = .ownServer
        addressError = nil
        guard let target = SSHTarget.parse(address) else {
            addressError = L10n.Onboarding.Server.invalidAddress
            return
        }
        checklist.reset()
        hostKeyError = nil
        phase = .installing
        #if DEBUG
        let installer = SSHInstaller(
            runner: runner, localBinary: devBinary, devArchive: devArchive, appVersion: Self.appVersion)
        #else
        let installer = SSHInstaller(runner: runner, appVersion: Self.appVersion)
        #endif
        run(installer.install(target: target.description, deviceName: DeviceDescriptor.current.name), app: app)
    }

    /// Step one of trusting a new host: scan it and show the fingerprint. Nothing is written.
    func reviewHost() async {
        guard let target = SSHTarget.parse(address) else { return }
        hostKeyError = nil
        do {
            let preview = try await SSHHostKeyTrust(runner: runner).preview(target)
            phase = .reviewingHost(preview)
        } catch SSHHostKeyError.viaProxy {
            // A jump host: the key cannot be reviewed from here. The person connects once in Terminal.
            proxyCommand = "ssh " + target.sshArguments.joined(separator: " ")
            hostKeyError = L10n.Onboarding.Server.viaProxy
        } catch {
            showHostKeyError(error)
        }
    }

    /// The text for a host-key failure. A conflicting old entry also gets the command that removes it.
    private func showHostKeyError(_ error: Error) {
        if let hostKey = error as? SSHHostKeyError, case .keyChangedSincePreviousVisit(let host) = hostKey {
            knownHostCommand = KnownHostRemoval.command(for: host)
        }
        hostKeyError = SignInMessages.text(for: error)
    }

    /// Step two, only after the person pressed "This is my server — trust it": the key is written, then the install retries.
    func trustHost(_ preview: HostKeyPreview, app: AppModel) async {
        guard let target = SSHTarget.parse(address) else { return }
        do {
            try await SSHHostKeyTrust(runner: runner).trust(preview, for: target)
            startOwnServer(app: app)
        } catch {
            if (error as? SSHHostKeyError) == .changedBetweenChecks {
                hostKeyError = L10n.Onboarding.Server.hostKeyChangedWhileReviewing
            } else {
                showHostKeyError(error)
            }
            phase = .failed
        }
    }

    /// Publishes the servers of this Mac to the account. A failure is shown to the person, with a retry.
    func syncServers(app: AppModel) {
        guard let hub = accountHub else { return }
        let configs = app.servers.map(\.config)
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            do {
                try await hub.publishServers(configs)
                self?.syncError = nil
            } catch {
                self?.syncError = SignInMessages.text(for: error)
            }
        }
    }

    /// The current failure, if the install failed.
    var failure: InstallError? {
        checklist.failure
    }

    /// Back to choosing, keeping the address.
    func backToChoice() {
        installTask?.cancel()
        checklist.reset()
        phase = .choosing
        option = nil
    }

    private func run(_ stream: AsyncStream<InstallEvent>, app: AppModel) {
        installTask?.cancel()
        installTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.checklist.apply(event)
                if case .done(let info) = event {
                    self.finish(info, app: app)
                }
            }
            guard let self else { return }
            if case .installing = self.phase, self.checklist.failure != nil {
                self.phase = .failed
            }
        }
    }

    private func finish(_ info: PairInfo, app: AppModel) {
        app.add(info.server)
        phase = .connected(info.server)
        if accountHub?.signedIn == true {
            syncServers(app: app)
        }
        if let model = app.servers.first(where: { $0.id == info.server.id }) {
            Task { [weak self] in
                await self?.setup.load(model)
            }
        }
    }

    /// Whether the host-key step applies: only for an unknown host, never for a changed key.
    var offersHostReview: Bool {
        guard case .sshFailed(let failure)? = checklist.failure else { return false }
        return failure == .hostKeyUnknown
    }
}

/// The part of the account payload that holds servers: the ssh servers of this Mac. A server on this Mac
/// (a local socket) is not synced, and neither is an endpoint whose address no longer parses.
/// The command that removes an old known_hosts entry. The host is quoted for a shell, so a name cannot add a command.
enum KnownHostRemoval {
    static func command(for host: String) -> String {
        "ssh-keygen -R '" + host.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum ServerSyncPayload {
    static func payload(for configs: [ServerConfig], now: Date = Date()) -> SyncPayload {
        var payload = SyncPayload()
        let addedAt = Int64(now.timeIntervalSince1970 * 1000)
        payload.servers = configs.compactMap { config in
            guard case .ssh(let text, _) = config.endpoint, let target = SSHTarget.parse(text) else { return nil }
            return SyncedServer(
                id: config.id, name: config.name,
                endpoint: .ssh(host: target.host, user: target.user, port: target.port), addedAt: addedAt)
        }
        return payload
    }
}

extension ServerSyncPayload {
    /// The servers of `remote`, with the ones of `local` added or replacing them by id. Other parts of the blob
    /// (keymap, snippets) are kept from `remote`.
    static func merge(local: SyncPayload, remote: SyncPayload) -> SyncPayload {
        var servers = remote.servers
        for server in local.servers {
            if let index = servers.firstIndex(where: { $0.id == server.id }) {
                servers[index] = server
            } else {
                servers.append(server)
            }
        }
        var merged = remote
        merged.servers = servers
        return merged
    }
}
