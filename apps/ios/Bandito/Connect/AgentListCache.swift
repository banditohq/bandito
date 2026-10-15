import BanditoKit
import Foundation

/// The last agent list of each server, kept on disk (one JSON file per server), so a phone that starts without a
/// connection still shows its team. It is a copy: the list read from the server replaces it (`ServerModel.seedCachedAgents`
/// takes it only before the first read).
struct AgentListCache {
    let directory: URL

    init(directory: URL = AgentListCache.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "AgentCache", directoryHint: .isDirectory)
    }

    func save(_ agents: [Agent], serverID: UUID) {
        guard let data = try? JSONEncoder().encode(agents) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(serverID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A copy that cannot be kept is only a missing convenience.
        }
    }

    /// The saved list, nil when there is none or the file cannot be read (a file of an older format is removed).
    func load(serverID: UUID) -> [Agent]? {
        let url = file(serverID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let agents = try? JSONDecoder().decode([Agent].self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return agents
    }

    func remove(serverID: UUID) {
        try? FileManager.default.removeItem(at: file(serverID))
    }

    private func file(_ serverID: UUID) -> URL {
        directory.appending(path: "\(serverID.uuidString).json")
    }
}
