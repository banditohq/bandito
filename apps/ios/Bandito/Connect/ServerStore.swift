import BanditoKit
import Foundation
import os

/// The saved list of servers (names and addresses, never tokens). A file in Application Support, marked as excluded from
/// backups (the addresses are of a person's Mac and network, and a token that stays on this iPhone makes a list restored
/// on another one useless anyway), readable after the first unlock. A list that an earlier version kept in UserDefaults
/// (`servers.v1`) is moved into the file at the first read.
///
/// The list is read record by record: a damaged record is skipped, the others are kept. A file that cannot be read at all
/// is never written over: the first save moves it aside (`servers.json.bad-<date>`), so nothing the person had is lost.
struct ServerStore {
    static let legacyKey = "servers.v1"
    private static let log = Logger(subsystem: "dev.bandito", category: "servers")

    let fileURL: URL
    let defaults: UserDefaults

    /// What a read found.
    enum Loaded: Equatable {
        /// The records that read (a damaged one is left out; `skipped` counts those), and the list is complete.
        case configs([ServerConfig], skipped: Int)
        /// No file, no old list: a first run.
        case empty
        /// The file is there and cannot be read now (before the first unlock after a restart): try again later, and do
        /// not write meanwhile.
        case unavailable
        /// The file is not a list at all.
        case unreadable
    }

    init(fileURL: URL = ServerStore.defaultFileURL(), defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "Bandito/servers.json")
    }

    /// One record of the file: it reads or it is nil.
    private struct Record: Decodable {
        let config: ServerConfig?

        init(from decoder: Decoder) throws {
            config = try? ServerConfig(from: decoder)
        }
    }

    /// The records of `data`: nil when it is not a list.
    private static func decode(_ data: Data) -> (configs: [ServerConfig], skipped: Int)? {
        guard let records = try? JSONDecoder().decode([Record].self, from: data) else { return nil }
        let configs = records.compactMap(\.config).map { config -> ServerConfig in
            var clean = config
            // Names from old or moved records are cleaned like every name.
            var fallback = "Server"
            if case .direct(let hosts, _) = config.endpoint, let first = hosts.first { fallback = first }
            clean.name = ServerNameRules.clean(config.name, fallback: fallback)
            return clean
        }
        return (configs, records.count - configs.count)
    }

    /// What the file holds, and what the old place holds when there is no file.
    func read() -> Loaded {
        let file = readFile()
        if file == .empty { return migrateLegacy() }
        return file
    }

    /// What the file holds. `.empty` when there is none.
    private func readFile() -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let ns = error as NSError
            let missing = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
            return missing ? .empty : .unavailable
        }
        guard let decoded = Self.decode(data) else {
            Self.log.error("the saved servers cannot be read; the file is kept")
            return .unreadable
        }
        if decoded.skipped > 0 { Self.log.error("\(decoded.skipped) saved servers could not be read and were left out") }
        return .configs(decoded.configs, skipped: decoded.skipped)
    }

    /// The records that read; nothing for a first run, an unavailable file or an unreadable one.
    func load() -> [ServerConfig] {
        if case .configs(let configs, _) = read() { return configs }
        return []
    }

    /// The old place: move what is there, then forget it.
    private func migrateLegacy() -> Loaded {
        guard let old = defaults.data(forKey: Self.legacyKey) else { return .empty }
        guard let decoded = Self.decode(old) else { return .unreadable }
        if decoded.configs.isEmpty || save(decoded.configs) { defaults.removeObject(forKey: Self.legacyKey) }
        return .configs(decoded.configs, skipped: decoded.skipped)
    }

    /// Writes the list. False when the file could not be written (the caller keeps working with what it has). A file
    /// that is there but cannot be read as a whole, or has records that do not read, is moved aside first, never
    /// written over; a file that cannot be read now (locked) is not touched at all.
    @discardableResult
    func save(_ configs: [ServerConfig]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch readFile() {
            case .unavailable:
                return false
            case .unreadable:
                try keepAside()
            case .configs(_, let skipped) where skipped > 0:
                try keepAside()
            case .configs, .empty:
                break
            }
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

    /// Moves the file to `servers.json.bad-<date>` (and out of backups too).
    private func keepAside() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var target = fileURL.deletingLastPathComponent().appending(path: fileURL.lastPathComponent + ".bad-" + stamp)
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = fileURL.deletingLastPathComponent().appending(path: fileURL.lastPathComponent + ".bad-" + stamp + "-\(n)")
        }
        try FileManager.default.moveItem(at: fileURL, to: target)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        Self.log.error("the saved servers were moved aside before a new list was written")
    }

    /// The files kept aside by `keepAside`.
    var asideFiles: [URL] {
        let dir = fileURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(fileURL.lastPathComponent + ".bad-") }.sorted().map { dir.appending(path: $0) }
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
