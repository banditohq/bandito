import BanditoKit
import Foundation
import Observation

/// App-wide state: saved servers and what is selected.
@MainActor
@Observable
public final class AppModel {
    public private(set) var servers: [ServerModel] = []
    public var selectedServerID: UUID?
    public var selectedAgentID: String?

    private static let storeKey = "servers.v1"

    public init() {
        load()
    }

    public var currentServer: ServerModel? {
        servers.first { $0.id == selectedServerID } ?? servers.first
    }

    public var selectedAgent: Agent? {
        guard let id = selectedAgentID else { return nil }
        return currentServer?.agents.first { $0.id == id }
    }

    public func connectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for s in servers {
                group.addTask { await s.connect() }
            }
        }
    }

    public func add(_ config: ServerConfig) {
        Keychain.setToken(config.token, for: config.id)
        let model = ServerModel(config: config)
        servers.append(model)
        selectedServerID = model.id
        save()
        Task { await model.connect() }
    }

    public func remove(_ id: UUID) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        let s = servers.remove(at: i)
        Task { await s.disconnect() }
        Keychain.setToken(nil, for: id)
        if selectedServerID == id { selectedServerID = servers.first?.id }
        save()
    }

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
            return ServerModel(config: c)
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
