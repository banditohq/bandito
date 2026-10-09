import Foundation

/// The folders a person picked recently on one server, most recent first (at most `limit`).
/// Kept in UserDefaults per server, so the list does not leak between servers.
public struct RecentFolders: Equatable, Sendable {
    public static let limit = 8

    public private(set) var paths: [String]

    public init(paths: [String] = []) {
        var unique: [String] = []
        for path in paths where !path.isEmpty && !unique.contains(path) {
            unique.append(path)
        }
        self.paths = Array(unique.prefix(Self.limit))
    }

    /// Moves `path` to the front. An empty path is ignored.
    public mutating func remember(_ path: String) {
        guard !path.isEmpty else { return }
        paths = Array(([path] + paths.filter { $0 != path }).prefix(Self.limit))
    }

    public static func load(serverID: String, defaults: UserDefaults = .standard) -> RecentFolders {
        RecentFolders(paths: defaults.stringArray(forKey: key(serverID: serverID)) ?? [])
    }

    public func save(serverID: String, defaults: UserDefaults = .standard) {
        defaults.set(paths, forKey: Self.key(serverID: serverID))
    }

    static func key(serverID: String) -> String {
        "recentFolders.\(serverID).v1"
    }
}
