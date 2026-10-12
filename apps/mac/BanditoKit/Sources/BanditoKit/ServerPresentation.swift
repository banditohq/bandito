import Foundation

// How a saved server looks and behaves for the person: its icon, its color, whether it opens first, its notifications,
// its place in the list. The choices are stored with the server in `servers.v1` (`ServerConfig`).

/// The icons a server can wear: SF Symbols. Its raw value is the symbol name that is stored.
public enum ServerIcon: String, CaseIterable, Sendable {
    case rack = "server.rack"
    case desktop = "desktopcomputer"
    case laptop = "laptopcomputer"
    case cloud = "cloud"
    case drive = "externaldrive"
    case bolt = "bolt"
    case globe = "globe"
    case house = "house"
}

/// The colors a server can wear. Each name is a color of the app's palette (`Color.Bandito`, `BanditoPalette`); the
/// mapping to a color is in BanditoUI.
public enum ServerTint: String, CaseIterable, Sendable {
    case signal, ok, info, danger, teal, purple, indigo, pink
}

/// The kinds of notice a server sends. `needsYou` waits for the person (an approval, or an answer that did not go
/// through); the others say that a turn ended.
public enum ServerNoticeKind: Sendable, Equatable {
    case needsYou, finished, failed
}

/// Which of a server's notifications reach the person. The global notification settings still apply on top.
public enum NotificationScope: String, Codable, CaseIterable, Sendable {
    /// Every notice the global settings allow.
    case all
    /// Only the notices that wait for the person.
    case needsYou
    /// No notice from this server.
    case off

    public func allows(_ kind: ServerNoticeKind) -> Bool {
        switch self {
        case .all: true
        case .needsYou: kind == .needsYou
        case .off: false
        }
    }
}

/// Rules over the saved list of servers: one main server, the order, the name the person types.
public enum ServerConfigRules {
    /// The longest name a server may have, in characters.
    public static let nameLimit = 60

    /// The name the person typed, trimmed and cut to `nameLimit`. nil when nothing is left: the old name stays.
    public static func cleanName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(nameLimit))
    }

    /// The list with `id` as its only main server. nil clears the main server: no server is main then.
    public static func settingPrimary(_ id: UUID?, in configs: [ServerConfig]) -> [ServerConfig] {
        configs.map { config in
            var updated = config
            updated.isPrimary = id != nil && config.id == id
            return updated
        }
    }

    /// A list read back with at most one main server: the first one that has the flag keeps it, the others lose it.
    /// A file edited by hand, or written by a future version, cannot make two servers open at launch.
    public static func normalizedPrimary(_ configs: [ServerConfig]) -> [ServerConfig] {
        var kept = false
        return configs.map { config in
            var updated = config
            if updated.isPrimary {
                if kept {
                    updated.isPrimary = false
                } else {
                    kept = true
                }
            }
            return updated
        }
    }

    /// The server that opens at launch: the main one, or the first one when none is main.
    public static func startupServerID(_ configs: [ServerConfig]) -> UUID? {
        (configs.first { $0.isPrimary } ?? configs.first)?.id
    }

    /// The list with `id` moved to `index` (0 is the first place). An index past the end puts it last. An id that the
    /// list does not have changes nothing.
    public static func moved(_ configs: [ServerConfig], id: UUID, to index: Int) -> [ServerConfig] {
        guard let from = configs.firstIndex(where: { $0.id == id }) else { return configs }
        var result = configs
        let item = result.remove(at: from)
        result.insert(item, at: min(max(index, 0), result.count))
        return result
    }
}
