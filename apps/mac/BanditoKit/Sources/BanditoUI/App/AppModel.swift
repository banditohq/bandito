import BanditoKit
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// App-wide state: saved servers and which one is in front. What is selected inside a server lives in `Router`.
@MainActor
@Observable
public final class AppModel {
    public private(set) var servers: [ServerModel] = []
    public var selectedServerID: UUID? {
        didSet {
            if oldValue != selectedServerID { onServerChanged?() }
        }
    }
    /// Asks the server in front for fresh limits each `ServerModel.usageBackgroundInterval` while the app is active.
    /// Runs until it is cancelled; the root view starts it once.
    public func keepUsageFresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(ServerModel.usageBackgroundInterval))
            #if os(macOS)
            guard NSApplication.shared.isActive else { continue }
            #endif
            await currentServer?.refreshUsageIfStale()
        }
    }

    /// Re-reads the agents of each connected server when the app comes back to the front, if the last read is old
    /// (see `ServerModel.refreshAgentsIfStale`). Runs until it is cancelled; the root view starts it once.
    public func watchAppActivation() async {
        #if os(macOS)
        for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
            for server in servers where server.state == .connected {
                server.refreshAgentsIfStale()
            }
        }
        #endif
    }

    /// Called when the server in front changes. The app drops the actions that were aimed at the old server.
    @ObservationIgnored public var onServerChanged: (() -> Void)?
    /// The last problem the user should know about (e.g. a token that could not be stored).
    public private(set) var lastError: String?
    /// Text size of every terminal pane (⌘+ ⌘− ⌘0 and pinch).
    public let terminalFont = TerminalFontStore()
    /// Keeps this Mac's daemon at the version of the app (see `LocalDaemonUpgradeModel`).
    let localUpgrade = LocalDaemonUpgradeModel()
    /// System notifications for agent events; nil until `startNotifications` runs.
    public private(set) var notifications: NotificationService?

    private static let storeKey = "servers.v1"
    #if os(macOS)
    /// One terminal controller per server, kept while the Terminals mode is away so output keeps being followed.
    @ObservationIgnored private var terminalControllers: [UUID: TerminalController] = [:]
    #endif

    public init() {
        load()
    }

    public var currentServer: ServerModel? {
        servers.first { $0.id == selectedServerID } ?? servers.first
    }

    /// Starts system notifications for live agent events (see `NotificationService`). Call once at launch.
    /// `selectedAgentID` and `windowActive` tell the rules what the user is looking at.
    public func startNotifications(selectedAgentID: @escaping () -> String?, windowActive: @escaping () -> Bool) {
        guard notifications == nil else { return }
        let sink = SystemNotificationSink()
        let service = NotificationService(
            sink: sink,
            settings: { NotificationSettings(defaults: .standard) },
            windowActive: windowActive,
            selectedAgentID: selectedAgentID,
            resolve: { [weak self] agentID, approvalID, decision in
                guard let server = self?.servers.first(where: { $0.agents.contains { $0.id == agentID } }) else {
                    throw AgentNotFoundError()
                }
                try await server.resolve(approvalID, decision, remember: false)
            })
        sink.service = service
        sink.start()
        notifications = service
    }

    /// Feeds one server's live events to the notifications. Servers added later are attached as they come.
    private func attachNotifications(_ server: ServerModel) {
        server.onLiveEvent = { [weak self, weak server] event in
            guard let self, let server else { return }
            // Answered in the app or on another device: the notification of that approval goes away.
            if case .approvalResolved(let approvalID, _, _, _) = event.body {
                self.notifications?.approvalSettled(approvalID)
            }
            guard let notice = Self.notice(for: event, in: server) else { return }
            self.notifications?.handle(notice)
        }
    }

    /// The notice an event makes, if any: an approval waiting, a finished turn, or an error.
    static func notice(for event: Event, in server: ServerModel) -> AgentNotice? {
        let name = server.agents.first { $0.id == event.agentId }?.name ?? ""
        switch event.body {
        case .approvalRequested(let approvalID, _, _, let title, let command, _, _):
            return .approval(
                agentID: event.agentId, agentName: name, approvalID: approvalID, title: title, command: command)
        case .turnCompleted(_, .ok, _, _):
            return .finished(agentID: event.agentId, agentName: name)
        case .error(let message):
            return .failed(agentID: event.agentId, agentName: name, message: message)
        default:
            return nil
        }
    }

    /// Marks the saved servers that are this Mac's daemon but were saved before the flag existed
    /// (`LocalDaemonUpgrade.confirmsThisMac`). The checks run in parallel, each with its own time limit. A confirmed
    /// server is replaced by a marked copy (`markThisMac`). A QA copy never reads this Mac's installed daemon.
    func confirmThisMacServers(
        binary: URL = LocalDaemonUpgrade.installedBinary(),
        runner: CommandRunner = ProcessCommandRunner(),
        timeout: Duration = .seconds(3)
    ) async {
        guard !QABuild.isRunningQA else { return }
        let candidates = servers.filter { !$0.config.isThisMac }.map(\.config)
        let confirmed = await withTaskGroup(of: UUID?.self) { group in
            for config in candidates {
                group.addTask {
                    await LocalDaemonUpgrade.confirmsThisMac(
                        config, binary: binary, runner: runner, timeout: timeout) ? config.id : nil
                }
            }
            var ids: [UUID] = []
            for await id in group {
                if let id { ids.append(id) }
            }
            return ids
        }
        for id in confirmed {
            await markThisMac(id)
        }
    }

    /// Replaces a confirmed server with a copy that has the flag. The old model is disconnected first. The list is
    /// read again after that await: the copy is made only if the same model is still there and still unmarked, so a
    /// change made meanwhile is not overwritten. The copy connects, and is checked for an upgrade.
    private func markThisMac(_ id: UUID) async {
        guard let old = servers.first(where: { $0.id == id }), !old.config.isThisMac else { return }
        await old.disconnect()
        guard let index = servers.firstIndex(where: { $0.id == id }),
            servers[index] === old, !servers[index].config.isThisMac
        else { return }
        var config = old.config
        config.isThisMac = true
        let rebuilt = ServerModel(config: config)
        attachNotifications(rebuilt)
        servers[index] = rebuilt
        // The waiting upgrade of the old model would hold the old model: it ends, and the copy starts its own.
        localUpgrade.forget(serverID: id)
        save()
        await rebuilt.connect()
        await localUpgrade.upgradeIfNeeded(rebuilt)
    }

    public func connectAll() async {
        await migrateLocalServers()
        // The check of this Mac's daemon runs beside the connects and does not hold them up. A server it confirms is
        // replaced and connected by `markThisMac`.
        Task { await confirmThisMacServers() }
        await withTaskGroup(of: Void.self) { group in
            for s in reachableServers {
                group.addTask { await s.connect() }
            }
        }
        // After the connects: each server has answered `daemon.info`, so its version is known.
        for s in reachableServers where s.state == .connected {
            await localUpgrade.upgradeIfNeeded(s)
        }
    }

    /// The servers this copy may talk to. A QA copy (`QABuild`) never reaches this Mac's own daemon: its `.local`
    /// servers, which are the owner's unix socket, are left alone.
    private var reachableServers: [ServerModel] {
        servers.filter { server in
            if QABuild.isRunningQA, case .local = server.config.endpoint { return false }
            return true
        }
    }

    /// Re-reads every connected server's `daemon.info` once an hour, so the update offer follows the daemon's own
    /// check (the daemon checks every 24 hours). Runs until the caller's task is cancelled.
    public func refreshDaemonInfoHourly() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
            for server in reachableServers {
                await server.refreshInfo()
            }
        }
    }

    /// Moves the saved `.local` servers (this Mac, over its unix socket) to the daemon's WebSocket with a device
    /// token (`LocalDaemonPairing`). It runs at each launch, before the connect, and a server that is moved is no
    /// longer `.local`, so it happens once. A server that cannot be paired yet stays `.local`; the next launch
    /// tries again. A token that cannot be kept is revoked on the daemon, so no device is left that nobody holds.
    /// Every failure is reported in `lastError`.
    func migrateLocalServers(
        pairing: LocalDaemonPairing = .installed(),
        storeToken: (String, UUID) -> Bool = { Keychain.setToken($0, for: $1) },
        revoke: (URL, String, String) async throws -> Void = { try await Pairing.revoke(url: $0, token: $1, deviceID: $2) }
    ) async {
        // A QA copy never installs or pairs with this Mac's daemon (~/.local/bin/bandito): nothing to migrate.
        guard !QABuild.isRunningQA else { return }
        let pending = servers.filter { server in
            if case .local = server.config.endpoint { true } else { false }
        }.map(\.id)
        var changed = false
        for id in pending {
            guard let old = servers.first(where: { $0.id == id }) else { continue }
            do {
                let paired = try await pairing.pair(
                    name: old.config.name, id: id, deviceName: Host.current().localizedName ?? "This Mac")
                guard let token = paired.config.token, storeToken(token, id) else {
                    await revokeUnkeptToken(paired, revoke: revoke)
                    continue
                }
                await old.disconnect()
                guard let index = servers.firstIndex(where: { $0.id == id }) else { continue }
                let model = ServerModel(config: paired.config)
                attachNotifications(model)
                servers[index] = model
                changed = true
            } catch {
                // Still `.local`: the next launch tries again.
                lastError = "This Mac's server could not be set up for the app: \(error.localizedDescription)"
            }
        }
        if changed { save() }
    }

    /// The device was paired, but its token could not be stored: the device is revoked on the daemon, and the
    /// server stays `.local` until the next launch.
    private func revokeUnkeptToken(
        _ paired: PairedServer,
        revoke: (URL, String, String) async throws -> Void
    ) async {
        var message = "Could not save this Mac's device token in the Keychain; the server stays local until the next launch."
        if case .webSocket(let url) = paired.config.endpoint, let token = paired.config.token {
            do {
                try await revoke(url, token, paired.deviceID)
            } catch {
                message += " Revoking the device on the server failed: \(error.localizedDescription)"
            }
        }
        lastError = message
    }

    public func add(_ config: ServerConfig) {
        // A server whose token cannot be stored could never authenticate: refuse it instead of adding a dead entry.
        guard Keychain.setToken(config.token, for: config.id) else {
            lastError = "Could not save the device token in the Keychain. The server was not added."
            return
        }
        // Connecting the same server again (a reinstall, "This Mac" twice) replaces its entry instead of
        // adding a second one: the new token is the valid one.
        if let existing = servers.first(where: { $0.config.endpoint == config.endpoint && $0.id != config.id }) {
            remove(existing.id)
        }
        lastError = nil
        let model = ServerModel(config: config)
        attachNotifications(model)
        servers.append(model)
        selectedServerID = model.id
        save()
        Task { await model.connect() }
    }

    public func remove(_ id: UUID) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        let s = servers.remove(at: i)
        localUpgrade.forget(serverID: id)
        #if os(macOS)
        if let controller = terminalControllers.removeValue(forKey: id) {
            Task { await controller.detachAll() }
        }
        #endif
        Task { await s.disconnect() }
        Keychain.setToken(nil, for: id)
        FileFavorites.forget(serverID: id)
        if selectedServerID == id { selectedServerID = servers.first?.id }
        save()
    }

    #if os(macOS)
    /// The terminals of `server`, created on first use.
    func terminalController(for server: ServerModel) -> TerminalController {
        if let existing = terminalControllers[server.id] {
            return existing
        }
        let controller = TerminalController(server: server, font: terminalFont)
        terminalControllers[server.id] = controller
        return controller
    }
    #endif

    private func load() {
        var configs: [ServerConfig] = []
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
            let saved = try? JSONDecoder().decode([ServerConfig].self, from: data)
        {
            configs = saved
        }
        servers = configs.map { c in
            var c = c
            c.token = Keychain.token(for: c.id)
            let model = ServerModel(config: c)
            attachNotifications(model)
            return model
        }
        selectedServerID = servers.first?.id
        #if DEBUG && os(macOS)
        // QA copies (scripts/qa): the server named by the launch arguments is added once. Not in release builds.
        QAHooks.addLaunchServer(to: self)
        #endif
    }

    private func save() {
        // Tokens never go to UserDefaults.
        let configs = servers.map { s -> ServerConfig in
            var c = s.config
            c.token = nil
            return c
        }
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
