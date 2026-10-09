import BanditoKit
import Foundation
import Observation

/// The Files sidebar's own choices, per server: the folders the user added to Favorites, and the built-in
/// places the user hid. Kept in UserDefaults. The sidebar and the browser share one store, so a folder added
/// from the list shows up in the sidebar at once.
///
/// Reads go to UserDefaults every time (nothing is cached during rendering); `revision` changes with every write,
/// so views that read the store render again.
@MainActor
@Observable
final class FileFavorites {
    @ObservationIgnored private let defaults: UserDefaults
    /// Changes with every write. Views read it, so they follow the store.
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func favoritesKey(_ serverID: UUID) -> String { "files.favorites.\(serverID.uuidString)" }
    static func hiddenKey(_ serverID: UUID) -> String { "files.hiddenPlaces.\(serverID.uuidString)" }

    /// Drops what is stored for a server that was removed from the app.
    static func forget(serverID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: favoritesKey(serverID))
        defaults.removeObject(forKey: hiddenKey(serverID))
    }

    /// The user's favorites of this server (absolute paths), in the order they were added.
    func paths(for serverID: UUID) -> [String] {
        _ = revision
        return FavoriteList(paths: defaults.stringArray(forKey: Self.favoritesKey(serverID)) ?? []).paths
    }

    func contains(_ path: String, serverID: UUID, home: String?) -> Bool {
        _ = revision
        guard let key = FavoritePath.normalized(path, home: home) else { return false }
        return paths(for: serverID).contains(key)
    }

    /// Adds a folder. Returns `false` when it is not an absolute path, is already a favorite, or is a built-in
    /// place (those are in the sidebar already).
    @discardableResult
    func add(_ path: String, serverID: UUID, home: String?, isMac: Bool) -> Bool {
        guard let key = FavoritePath.normalized(path, home: home),
              !FavoritePath.builtInPaths(home: home, isMac: isMac).contains(key)
        else { return false }
        var list = FavoriteList(paths: paths(for: serverID))
        guard !list.contains(key) else { return false }
        list.add(key)
        write(list.paths, serverID: serverID)
        return true
    }

    func remove(_ path: String, serverID: UUID, home: String?) {
        guard let key = FavoritePath.normalized(path, home: home) else { return }
        var list = FavoriteList(paths: paths(for: serverID))
        list.remove(key)
        write(list.paths, serverID: serverID)
    }

    /// Built-in places the user hid ("Hide" in their menu), by path as the sidebar names them (`~/Downloads`).
    func hidden(for serverID: UUID) -> [String] {
        _ = revision
        return defaults.stringArray(forKey: Self.hiddenKey(serverID)) ?? []
    }

    func hide(_ path: String, serverID: UUID) {
        var updated = hidden(for: serverID)
        guard !updated.contains(path) else { return }
        updated.append(path)
        defaults.set(updated, forKey: Self.hiddenKey(serverID))
        revision += 1
    }

    /// Shows the built-in places again.
    func unhideAll(serverID: UUID) {
        defaults.removeObject(forKey: Self.hiddenKey(serverID))
        revision += 1
    }

    private func write(_ paths: [String], serverID: UUID) {
        defaults.set(paths, forKey: Self.favoritesKey(serverID))
        revision += 1
    }
}
