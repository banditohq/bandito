import Foundation
import Testing

@testable import BanditoUI

/// Back and forward in Files walk the folders of the server, not the modes; "Terminal here" keeps its folder
/// until the Terminals mode takes it.
@MainActor
@Suite struct FilesNavigationTests {
    @Test func backAndForwardInFilesWalkFolderHistoryNotModes() {
        let router = Router(mode: .team)
        let server = UUID()
        router.files.bind(to: server)
        router.select(mode: .files)
        router.files.arrive(at: "/a", serverID: server)
        router.files.arrive(at: "/a/b", serverID: server)

        #expect(router.canGoBack)
        #expect(!router.canGoForward)

        router.back()
        #expect(router.mode == .files)
        #expect(router.filesPath == "/a")
        #expect(router.canGoForward)

        // Nothing before "/a": the chats are not behind it, so back does nothing.
        #expect(!router.canGoBack)
        router.back()
        #expect(router.mode == .files)
        #expect(router.filesPath == "/a")

        router.forward()
        #expect(router.mode == .files)
        #expect(router.filesPath == "/a/b")
        #expect(!router.canGoForward)
    }

    @Test func stepsOnlyCountTheFoldersOfTheServerInFront() {
        let router = Router(mode: .team)
        let first = UUID()
        let second = UUID()
        router.files.bind(to: first)
        router.select(mode: .files)
        router.files.arrive(at: "/one", serverID: first)
        router.files.arrive(at: "/one/two", serverID: first)

        router.files.bind(to: second)
        #expect(!router.canGoBack)
        router.files.arrive(at: "/other", serverID: second)
        #expect(!router.canGoBack)

        router.files.bind(to: first)
        #expect(router.canGoBack)
    }

    @Test func stepBackClosesTheViewerSoTheChosenFolderShows() {
        let router = Router(mode: .team)
        let server = UUID()
        router.files.bind(to: server)
        router.select(mode: .files)
        router.files.arrive(at: "/a", serverID: server)
        router.files.arrive(at: "/a/b", serverID: server)
        router.files.showsViewer = true

        router.back()
        #expect(!router.files.showsViewer)
        #expect(router.filesPath == "/a")
    }

    @Test func backWithNoFolderLeftClosesTheViewer() {
        let router = Router(mode: .team)
        let server = UUID()
        router.files.bind(to: server)
        router.select(mode: .files)
        router.files.arrive(at: "/a", serverID: server)
        router.files.showsViewer = true

        #expect(router.canGoBack)
        router.back()
        #expect(!router.files.showsViewer)
        #expect(router.mode == .files)
        #expect(!router.canGoBack)
    }

    @Test func openTerminalHereSelectsTerminalsAndKeepsTheFolderUntilTaken() {
        let router = Router(mode: .files)
        router.openTerminalHere("/Users/dev/work")
        #expect(router.mode == .terminals)
        #expect(router.pendingTerminalCwd == "/Users/dev/work")
        #expect(router.takeTerminalCwd() == "/Users/dev/work")
        #expect(router.takeTerminalCwd() == nil)
    }
}
