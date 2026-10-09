import BanditoKit
import Foundation

/// The "Projects" place: the folder that holds the most projects the server found.
enum ProjectsRoot {
    /// Folders with these in their path are not places to browse: dot folders, Library, dependencies, caches.
    static func isBrowsable(_ path: String) -> Bool {
        path.split(separator: "/").allSatisfy { segment in
            let name = String(segment)
            return !name.hasPrefix(".")
                && name != "Library"
                && name != "node_modules"
                && !name.lowercased().contains("cache")
        }
    }

    /// The parent folder that holds the most browsable projects. A tie goes to the smaller path, so the place
    /// does not jump between loads. `nil` when no folder qualifies (the place is then not shown).
    static func pick(_ projects: [ProjectHint]) -> String? {
        var counts: [String: Int] = [:]
        for project in projects where isBrowsable(project.path) {
            guard let parent = FilePath.parent(of: project.path), parent != "/" else { continue }
            counts[parent, default: 0] += 1
        }
        return counts.min { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }?.key
    }
}

/// Favorite folders of one server, in the order they were added. A path is listed once.
struct FavoriteList: Equatable, Sendable {
    private(set) var paths: [String] = []

    init(paths: [String] = []) {
        for path in paths { add(path) }
    }

    func contains(_ path: String) -> Bool {
        paths.contains(path)
    }

    mutating func add(_ path: String) {
        guard !contains(path) else { return }
        paths.append(path)
    }

    mutating func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }
}

/// Favorite folders are kept as absolute paths without a trailing slash, so one folder has one spelling.
enum FavoritePath {
    /// `path` with `~` made absolute and trailing slashes dropped (the root stays `/`). `nil` when the result
    /// is not absolute: a `~` path with no home to expand it with cannot be stored yet.
    static func normalized(_ path: String, home: String?) -> String? {
        var result = FilePath.expandHome(path, home: home)
        guard result.hasPrefix("/") else { return nil }
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// The places the sidebar shows by itself (home, Downloads, the agents' memory, and on Linux the logs).
    /// They are never added as favorites: they are already there.
    static func builtInPaths(home: String?, isMac: Bool) -> [String] {
        var paths = ["~", "~/Downloads", "~/bandito/agents"]
        if !isMac { paths.append("/var/log") }
        return paths.compactMap { normalized($0, home: home) }
    }

    static func isBuiltIn(_ path: String, home: String?, isMac: Bool) -> Bool {
        guard let key = normalized(path, home: home) else { return false }
        return builtInPaths(home: home, isMac: isMac).contains(key)
    }
}

/// Which server is this Mac and which runs macOS. Both decide the Trash place and the "Show in Finder" action.
enum FilesServer {
    /// The daemon on this Mac: the local socket, or a WebSocket to the loopback address.
    static func isThisMac(_ endpoint: ServerEndpoint) -> Bool {
        switch endpoint {
        case .local:
            return true
        case .webSocket(let url):
            let host = (url.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return ["127.0.0.1", "::1", "localhost"].contains(host)
        case .ssh:
            return false
        }
    }

    /// The OS string the daemon reports (`ServerInfo.os`), macOS or Darwin.
    static func isMac(os: String?) -> Bool {
        guard let os = os?.lowercased() else { return false }
        return os.contains("mac") || os.contains("darwin")
    }
}

extension FilePath {
    /// `~` and `~/…` made absolute with the home folder. Without a known home, the path is returned as it is.
    static func expandHome(_ path: String, home: String?) -> String {
        guard let home else { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// The Trash of a Mac user (`~/.Trash`), written with `~` or as an absolute path.
    static func isMacTrash(_ path: String, home: String?) -> Bool {
        let expanded = expandHome(path, home: home)
        if expanded == "~/.Trash" { return true }
        guard let home else { return false }
        return expanded == home + "/.Trash"
    }
}
