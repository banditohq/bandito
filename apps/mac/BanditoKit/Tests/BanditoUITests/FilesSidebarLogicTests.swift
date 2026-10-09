@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Pure logic behind the Files sidebar and its menus: the projects place, favorites, which server is this Mac,
/// and the home-relative paths.
@MainActor
@Suite struct FilesSidebarLogicTests {
    static func project(_ path: String) -> ProjectHint {
        ProjectHint(path: path, name: String(path.split(separator: "/").last ?? ""), isGit: true, modifiedMs: 0)
    }

    // MARK: Projects place

    @Test func projectsRootIsTheParentWithTheMostProjects() {
        let root = ProjectsRoot.pick([
            Self.project("/Users/dev/work/api"),
            Self.project("/Users/dev/work/web"),
            Self.project("/Users/dev/work/app"),
            Self.project("/Users/dev/tools/cli"),
        ])
        #expect(root == "/Users/dev/work")
    }

    @Test func projectsRootIgnoresHiddenLibraryNodeModulesAndCaches() {
        let root = ProjectsRoot.pick([
            Self.project("/Users/dev/.cargo/registry/x"),
            Self.project("/Users/dev/Library/Mobile/a"),
            Self.project("/Users/dev/app/node_modules/pkg"),
            Self.project("/Users/dev/.npm/_cacache/b"),
            Self.project("/Users/dev/place-cache/c"),
            Self.project("/Users/dev/Caches/d"),
            Self.project("/Users/dev/work/api"),
        ])
        #expect(root == "/Users/dev/work")
    }

    @Test func projectsRootIsNilWhenNothingQualifies() {
        #expect(ProjectsRoot.pick([]) == nil)
        #expect(ProjectsRoot.pick([Self.project("/Users/dev/.cache/x")]) == nil)
    }

    @Test func projectsRootTieGoesToTheSmallerPathSoItIsStable() {
        let root = ProjectsRoot.pick([
            Self.project("/b/one"), Self.project("/a/two"),
        ])
        #expect(root == "/a")
    }

    // MARK: Favorites

    @Test func favoritesKeepTheOrderTheyWereAddedIn() {
        var list = FavoriteList()
        list.add("/w/second")
        list.add("/w/first")
        list.add("/w/third")
        #expect(list.paths == ["/w/second", "/w/first", "/w/third"])
    }

    @Test func favoritesDoNotRepeatAndRemove() {
        var list = FavoriteList()
        list.add("/w/a")
        list.add("/w/a")
        #expect(list.paths == ["/w/a"])
        #expect(list.contains("/w/a"))
        list.remove("/w/a")
        #expect(list.paths.isEmpty)
        #expect(!list.contains("/w/a"))
    }

    @Test func favoritesStoreReadsAndWritesDefaultsPerServer() throws {
        let suite = try #require(UserDefaults(suiteName: "FilesSidebarLogicTests.\(UUID().uuidString)"))
        let store = FileFavorites(defaults: suite)
        let first = UUID()
        let second = UUID()
        #expect(store.add("/w/a", serverID: first, home: nil, isMac: false))
        #expect(store.add("/w/b", serverID: second, home: nil, isMac: false))
        #expect(store.paths(for: first) == ["/w/a"])
        #expect(store.paths(for: second) == ["/w/b"])
        // A new store over the same defaults sees what was saved.
        #expect(FileFavorites(defaults: suite).paths(for: first) == ["/w/a"])
        store.remove("/w/a", serverID: first, home: nil)
        #expect(FileFavorites(defaults: suite).paths(for: first).isEmpty)
    }

    @Test func favoritesAreStoredOneSpellingPerFolder() throws {
        let suite = try #require(UserDefaults(suiteName: "FilesSidebarLogicTests.\(UUID().uuidString)"))
        let store = FileFavorites(defaults: suite)
        let server = UUID()
        #expect(store.add("/w/app", serverID: server, home: "/Users/dev", isMac: true))
        #expect(!store.add("/w/app/", serverID: server, home: "/Users/dev", isMac: true))
        #expect(store.paths(for: server) == ["/w/app"])
        #expect(store.contains("/w/app/", serverID: server, home: "/Users/dev"))
        store.remove("/w/app/", serverID: server, home: "/Users/dev")
        #expect(store.paths(for: server).isEmpty)
    }

    @Test func tildeFavoritesAreStoredAbsoluteOrNotAtAll() throws {
        let suite = try #require(UserDefaults(suiteName: "FilesSidebarLogicTests.\(UUID().uuidString)"))
        let store = FileFavorites(defaults: suite)
        let server = UUID()
        // Without a home there is nothing to expand the tilde with.
        #expect(!store.add("~/work", serverID: server, home: nil, isMac: true))
        #expect(store.add("~/work", serverID: server, home: "/Users/dev", isMac: true))
        #expect(store.paths(for: server) == ["/Users/dev/work"])
        #expect(store.contains("/Users/dev/work/", serverID: server, home: "/Users/dev"))
        #expect(store.contains("~/work", serverID: server, home: "/Users/dev"))
    }

    @Test func builtInPlacesCannotBeAddedAsFavorites() throws {
        let suite = try #require(UserDefaults(suiteName: "FilesSidebarLogicTests.\(UUID().uuidString)"))
        let store = FileFavorites(defaults: suite)
        let server = UUID()
        #expect(!store.add("~", serverID: server, home: "/Users/dev", isMac: true))
        #expect(!store.add("/Users/dev/Downloads/", serverID: server, home: "/Users/dev", isMac: true))
        #expect(!store.add("~/bandito/agents", serverID: server, home: "/Users/dev", isMac: true))
        // /var/log is a built-in place only on Linux.
        #expect(!store.add("/var/log", serverID: server, home: "/Users/dev", isMac: false))
        #expect(store.add("/var/log", serverID: server, home: "/Users/dev", isMac: true))
        #expect(store.paths(for: server) == ["/var/log"])
    }

    @Test func forgettingAServerDropsItsStoredChoices() throws {
        let suite = try #require(UserDefaults(suiteName: "FilesSidebarLogicTests.\(UUID().uuidString)"))
        let store = FileFavorites(defaults: suite)
        let server = UUID()
        store.add("/w/a", serverID: server, home: nil, isMac: false)
        store.hide("~/Downloads", serverID: server)
        FileFavorites.forget(serverID: server, defaults: suite)
        #expect(FileFavorites(defaults: suite).paths(for: server).isEmpty)
        #expect(FileFavorites(defaults: suite).hidden(for: server).isEmpty)
    }

    @Test func builtInPathsAreTheSidebarPlaces() {
        #expect(FavoritePath.builtInPaths(home: "/Users/dev", isMac: true) == [
            "/Users/dev", "/Users/dev/Downloads", "/Users/dev/bandito/agents",
        ])
        #expect(FavoritePath.builtInPaths(home: "/home/dev", isMac: false).contains("/var/log"))
    }

    @Test func hiddenBuiltInPlacesAreKeptPerServer() throws {
        let suite = try #require(UserDefaults(suiteName: "FilesSidebarLogicTests.\(UUID().uuidString)"))
        let store = FileFavorites(defaults: suite)
        let server = UUID()
        store.hide("~/Downloads", serverID: server)
        #expect(store.hidden(for: server) == ["~/Downloads"])
        store.unhideAll(serverID: server)
        #expect(store.hidden(for: server).isEmpty)
    }

    // MARK: Which server is this Mac

    @Test func localEndpointIsThisMacAndLoopbackWebSocketToo() throws {
        #expect(FilesServer.isThisMac(.local(socketPath: "/tmp/x.sock")))
        #expect(FilesServer.isThisMac(.webSocket(url: try #require(URL(string: "ws://127.0.0.1:7878/v1/rpc")))))
        #expect(FilesServer.isThisMac(.webSocket(url: try #require(URL(string: "ws://localhost:7878/v1/rpc")))))
        #expect(!FilesServer.isThisMac(.webSocket(url: try #require(URL(string: "wss://mac.tail.net/v1/rpc")))))
        #expect(!FilesServer.isThisMac(.ssh(target: "new", remotePort: 7878)))
    }

    @Test func macOSIsRecognisedFromTheServerOS() {
        #expect(FilesServer.isMac(os: "macOS 15.1"))
        #expect(FilesServer.isMac(os: "Darwin"))
        #expect(!FilesServer.isMac(os: "Ubuntu 24.04"))
        #expect(!FilesServer.isMac(os: nil))
    }

    // MARK: Home-relative paths

    @Test func tildePathsExpandToTheHomeFolder() {
        #expect(FilePath.expandHome("~", home: "/Users/dev") == "/Users/dev")
        #expect(FilePath.expandHome("~/Downloads", home: "/Users/dev") == "/Users/dev/Downloads")
        #expect(FilePath.expandHome("/var/log", home: "/Users/dev") == "/var/log")
        #expect(FilePath.expandHome("~/Downloads", home: nil) == "~/Downloads")
    }

    @Test func macTrashIsRecognisedInHomeOrAsTilde() {
        #expect(FilePath.isMacTrash("~/.Trash", home: "/Users/dev"))
        #expect(FilePath.isMacTrash("/Users/dev/.Trash", home: "/Users/dev"))
        #expect(!FilePath.isMacTrash("/Users/dev/Trash", home: "/Users/dev"))
        #expect(!FilePath.isMacTrash("/Users/dev/.Trash/sub", home: "/Users/dev"))
    }
}
