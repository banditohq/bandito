import BanditoKit
import Foundation

/// The saved list of servers (names and addresses, never tokens). A file in Application Support, marked as excluded from
/// backups (the addresses are of a person's Mac and network, and a token that stays on this iPhone makes a list restored
/// on another one useless anyway), readable after the first unlock. A list that an earlier version kept in UserDefaults
/// (`servers.v1`) is moved into the file at the first read.
struct ServerStore {
    static let legacyKey = "servers.v1"

    let fileURL: URL
    let defaults: UserDefaults

    init(fileURL: URL = ServerStore.defaultFileURL(), defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "Bandito/servers.json")
    }

    func load() -> [ServerConfig] {
        if let data = try? Data(contentsOf: fileURL) {
            return (try? JSONDecoder().decode([ServerConfig].self, from: data)) ?? []
        }
        // The old place: move what is there, then forget it.
        guard let old = defaults.data(forKey: Self.legacyKey) else { return [] }
        let configs = (try? JSONDecoder().decode([ServerConfig].self, from: old)) ?? []
        if configs.isEmpty || save(configs) { defaults.removeObject(forKey: Self.legacyKey) }
        return configs
    }

    /// Writes the list. False when the file could not be written (the caller keeps working with what it has).
    @discardableResult
    func save(_ configs: [ServerConfig]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(configs)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        defaults.removeObject(forKey: Self.legacyKey)
    }

    /// Whether the file is marked as left out of backups.
    var isExcludedFromBackup: Bool {
        (try? fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }
}
