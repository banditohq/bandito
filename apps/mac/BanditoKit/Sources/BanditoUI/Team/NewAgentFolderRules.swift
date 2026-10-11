import Foundation

/// The agent's own folder in the new agent sheet ("New folder"): its name, the agents folder it goes into, and the
/// free name it gets. Pure, so the rules are tested in BanditoUITests; the sheet asks the server and makes the folder.
enum NewAgentFolderRules {
    /// The longest folder name, in characters.
    static let nameLimit = 64
    /// How many names are tried (`Forge`, `Forge 2`, …) before the sheet gives up.
    static let attemptLimit = 200
    /// The agents folder when nothing else says where it is: `Bandito` in the home folder of the server's user.
    static let defaultRootName = "Bandito"

    private static let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    /// The folder name for an agent's name: characters a folder cannot have, and control characters, become `-`.
    /// Spaces at the ends are trimmed and the name is cut to `nameLimit`. Empty, "." and ".." give "agent".
    static func folderName(for agentName: String) -> String {
        var mapped = ""
        for scalar in agentName.unicodeScalars {
            if forbidden.contains(Character(scalar)) || CharacterSet.controlCharacters.contains(scalar) {
                mapped.append("-")
            } else {
                mapped.unicodeScalars.append(scalar)
            }
        }
        let cut = mapped.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty || cut == "." || cut == ".." ? "agent" : cut
    }

    /// The name tried for the given attempt: the name itself first, then ` 2`, ` 3`… The base is cut so the whole
    /// name stays within `nameLimit`.
    static func candidate(base: String, attempt: Int) -> String {
        guard attempt > 1 else { return base }
        let suffix = " \(attempt)"
        let head = base.prefix(nameLimit - suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return head + suffix
    }

    /// The path of a folder `name` inside `root`. A trailing slash on the root does not double.
    static func folderPath(root: String, name: String) -> String {
        let base = trimmedSlash(root)
        return (base == "/" ? "" : base) + "/" + name
    }

    /// The folder above `path` (`/home/me/billing` gives `/home/me`, `/billing` gives `/`). Nil for the root or a
    /// relative path.
    static func parent(of path: String) -> String? {
        let trimmed = trimmedSlash(path)
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return nil }
        let head = String(trimmed[..<slash])
        return head.isEmpty ? "/" : head
    }

    /// The project folder of an agent: its `cwd`, unless the agent has none or works in its own folder (`homeDir`).
    static func projectFolder(cwd: String, homeDir: String?) -> String? {
        let folder = trimmedSlash(cwd.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folder.isEmpty else { return nil }
        if let homeDir, trimmedSlash(homeDir) == folder { return nil }
        return folder
    }

    /// The agents folder a new agent goes into, when the person has not chosen one on this server:
    /// the saved one; else the parent that holds the most project folders (at least two agents in it; a tie goes to
    /// the parent listed first); else `Bandito` in the home folder. Nil when none of these is known.
    static func defaultRoot(saved: String?, projectFolders: [String], home: String?) -> String? {
        if let saved = saved?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return trimmedSlash(saved)
        }
        var counts: [(parent: String, count: Int)] = []
        for folder in projectFolders {
            guard let parent = parent(of: folder) else { continue }
            if let index = counts.firstIndex(where: { $0.parent == parent }) {
                counts[index].count += 1
            } else {
                counts.append((parent: parent, count: 1))
            }
        }
        var best: (parent: String, count: Int)?
        for entry in counts where entry.count >= 2 && entry.count > (best?.count ?? 0) {
            best = entry
        }
        if let best {
            return best.parent
        }
        guard let home, !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return folderPath(root: home, name: defaultRootName)
    }

    private static func trimmedSlash(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

/// What the sheet finds at the folder an agent would get: nothing (it is made), an empty folder (used as it is), or
/// something that is taken (a file, or a folder with things in it), so the next name is tried.
enum AgentFolderSlot: Equatable {
    case missing, empty, taken
}

/// The agents folder a person chose on one server. Kept in UserDefaults per server, under `agents.root.<serverID>`.
enum AgentsRootStore {
    static func load(serverID: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(serverID: serverID))
    }

    static func save(_ root: String, serverID: String, defaults: UserDefaults = .standard) {
        defaults.set(root, forKey: key(serverID: serverID))
    }

    static func key(serverID: String) -> String {
        "agents.root.\(serverID)"
    }
}
