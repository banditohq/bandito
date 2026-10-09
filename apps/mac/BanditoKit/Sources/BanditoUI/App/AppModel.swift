import BanditoKit
import Foundation
import Observation

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
    /// Called when the server in front changes. The app drops the actions that were aimed at the old server.
    @ObservationIgnored public var onServerChanged: (() -> Void)?
    /// The last problem the user should know about (e.g. a token that could not be stored).
    public private(set) var lastError: String?
    /// Text size of every terminal pane (⌘+ ⌘− ⌘0 and pinch).
    public let terminalFont = TerminalFontStore()
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

    public func connectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for s in servers {
                group.addTask { await s.connect() }
            }
        }
    }

    public func add(_ config: ServerConfig) {
        // A server whose token cannot be stored could never authenticate: refuse it instead of adding a dead entry.
        guard Keychain.setToken(config.token, for: config.id) else {
            lastError = "Could not save the device token in the Keychain. The server was not added."
            return
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
        #if os(macOS)
        if let controller = terminalControllers.removeValue(forKey: id) {
            Task { await controller.detachAll() }
        }
        #endif
        Task { await s.disconnect() }
        Keychain.setToken(nil, for: id)
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
        if configs.isEmpty {
            configs = [ServerConfig(name: Host.current().localizedName ?? "This Mac", endpoint: .defaultLocal)]
        }
        servers = configs.map { c in
            var c = c
            c.token = Keychain.token(for: c.id)
            let model = ServerModel(config: c)
            attachNotifications(model)
            return model
        }
        selectedServerID = servers.first?.id
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
