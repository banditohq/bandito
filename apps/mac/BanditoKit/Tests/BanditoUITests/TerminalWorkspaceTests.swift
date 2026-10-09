import Foundation
import Testing

@testable import BanditoUI

@MainActor
@Suite struct TerminalWorkspaceTests {
    static let now = Date(timeIntervalSince1970: 1_000)

    /// A workspace with its own UserDefaults suite, so tests never touch the real preferences.
    static func makeWorkspace(serverID: UUID = UUID(), defaults: UserDefaults? = nil) -> TerminalWorkspace {
        let suite = defaults ?? UserDefaults(suiteName: "bandito.tests.\(UUID().uuidString)")!
        return TerminalWorkspace(serverID: serverID, defaults: suite)
    }

    @Test func addingPanesGrowsTheLayoutAndFocusesTheNewOne() {
        let ws = Self.makeWorkspace()
        ws.add("a", at: Self.now)
        #expect(ws.onScreen == ["a"])
        #expect(ws.layout == .one)
        #expect(ws.focusedID == "a")

        ws.add("b", at: Self.now)
        ws.add("c", at: Self.now)
        #expect(ws.onScreen == ["a", "b", "c"])
        #expect(ws.layout == .mainRight)
        #expect(ws.focusedID == "c")
    }

    @Test func fifthPaneWaitsInTheDock() {
        let ws = Self.makeWorkspace()
        for id in ["a", "b", "c", "d"] { ws.add(id, at: Self.now) }
        #expect(ws.layout == .grid)
        ws.add("e", at: Self.now)
        #expect(ws.onScreen == ["a", "b", "c", "d"])
        #expect(ws.collapsed.map(\.id) == ["e"])
        #expect(ws.collapsed.first?.lines == nil)
    }

    @Test func collapseMovesThePaneToTheDockAndKeepsFocusOnScreen() {
        let ws = Self.makeWorkspace()
        ws.add("a", at: Self.now)
        ws.add("b", at: Self.now)
        ws.collapse("b", at: Self.now, lines: 7)
        #expect(ws.onScreen == ["a"])
        #expect(ws.collapsed.map(\.id) == ["b"])
        #expect(ws.collapsed.first?.lines == 7)
        #expect(ws.focusedID == "a")
    }

    @Test func restoreBringsBackTheLastCollapsedPane() {
        let ws = Self.makeWorkspace()
        ws.add("a", at: Self.now)
        ws.add("b", at: Self.now)
        ws.collapse("a", at: Self.now, lines: 0)
        ws.collapse("b", at: Self.now, lines: 0)
        #expect(ws.onScreen.isEmpty)

        #expect(ws.restoreLast() == "b")
        #expect(ws.onScreen == ["b"])
        #expect(ws.collapsed.map(\.id) == ["a"])
        #expect(ws.focusedID == "b")

        #expect(ws.restore("a"))
        #expect(ws.onScreen == ["b", "a"])
        #expect(ws.collapsed.isEmpty)
        #expect(ws.restoreLast() == nil)
    }

    @Test func restoreFailsWhenTheGridIsFull() {
        let ws = Self.makeWorkspace()
        for id in ["a", "b", "c", "d"] { ws.add(id, at: Self.now) }
        ws.add("e", at: Self.now)  // screen full: goes to the dock
        #expect(ws.collapsed.map(\.id) == ["e"])
        #expect(ws.restore("e") == false)
        #expect(ws.collapsed.map(\.id) == ["e"])
    }

    @Test func closeRemovesFromEitherPlaceAndFixesFocus() {
        let ws = Self.makeWorkspace()
        ws.add("a", at: Self.now)
        ws.add("b", at: Self.now)
        ws.collapse("a", at: Self.now, lines: 0)
        ws.close("b")
        #expect(ws.onScreen.isEmpty)
        #expect(ws.focusedID == nil)
        ws.close("a")
        #expect(ws.collapsed.isEmpty)
    }

    @Test func layoutChangeToSmallerCollapsesTheTail() {
        let ws = Self.makeWorkspace()
        for id in ["a", "b", "c"] { ws.add(id, at: Self.now) }
        ws.setLayout(.one, at: Self.now)
        #expect(ws.layout == .one)
        #expect(ws.onScreen == ["a"])
        #expect(ws.collapsed.map(\.id) == ["b", "c"])
    }

    @Test func fullscreenOnlyForPanesOnScreen() {
        let ws = Self.makeWorkspace()
        ws.add("a", at: Self.now)
        ws.add("b", at: Self.now)
        ws.collapse("b", at: Self.now, lines: 0)
        ws.toggleFullscreen("b")
        #expect(ws.fullscreenID == nil)
        ws.toggleFullscreen("a")
        #expect(ws.fullscreenID == "a")
        ws.toggleFullscreen("a")
        #expect(ws.fullscreenID == nil)
    }

    @Test func moveFocusFollowsTheLayoutNeighbors() {
        let ws = Self.makeWorkspace()
        for id in ["a", "b", "c", "d"] { ws.add(id, at: Self.now) }
        ws.focus("a")
        ws.move(.down)
        #expect(ws.focusedID == "c")
        ws.move(.right)
        #expect(ws.focusedID == "d")
        ws.move(.right)
        #expect(ws.focusedID == "d")
    }

    @Test func replaceKeepsThePlacement() {
        let ws = Self.makeWorkspace()
        for id in ["a", "b"] { ws.add(id, at: Self.now) }
        ws.focus("a")
        ws.replace("a", with: "x")
        #expect(ws.onScreen == ["x", "b"])
        #expect(ws.focusedID == "x")
    }

    @Test func reconcileDropsGoneTerminalsAndDocksUnknownOnes() {
        let ws = Self.makeWorkspace()
        ws.add("a", at: Self.now)
        ws.add("gone", at: Self.now)
        // The server has a and two terminals the app has never seen (c is older than b).
        ws.reconcile(serverTerminals: [("a", 100), ("b", 300), ("c", 200)])
        #expect(ws.onScreen == ["a"])
        #expect(ws.collapsed.map(\.id) == ["c", "b"])
        #expect(ws.collapsed.allSatisfy { $0.lines == nil })
    }

    @Test func stateSurvivesARestart() {
        let suite = UserDefaults(suiteName: "bandito.tests.\(UUID().uuidString)")!
        let serverID = UUID()
        let first = Self.makeWorkspace(serverID: serverID, defaults: suite)
        first.add("a", at: Self.now)
        first.add("b", at: Self.now)
        first.collapse("b", at: Self.now, lines: 3)
        first.setLayout(.cols, at: Self.now)
        first.inputToAll = true

        let second = Self.makeWorkspace(serverID: serverID, defaults: suite)
        #expect(second.layout == .cols)
        #expect(second.onScreen == ["a"])
        #expect(second.collapsed.map(\.id) == ["b"])
        // The line baseline is per run: a restored pane has no "+N lines" yet.
        #expect(second.collapsed.first?.lines == nil)
        #expect(second.inputToAll)
    }

    @Test func differentServersKeepSeparateState() {
        let suite = UserDefaults(suiteName: "bandito.tests.\(UUID().uuidString)")!
        let one = Self.makeWorkspace(defaults: suite)
        one.add("a", at: Self.now)
        let other = Self.makeWorkspace(defaults: suite)
        #expect(other.onScreen.isEmpty)
    }
}
