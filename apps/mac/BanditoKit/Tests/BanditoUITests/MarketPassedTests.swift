#if os(macOS)
import BanditoKit
import Foundation
import SwiftUI
import Testing

@testable import BanditoUI

/// The header and the kept Bots and Skills pages are handed over as the same bytes while what they show is the same:
/// SwiftUI compares bytes until it has laid out a view's type, and a closure or an array made at each pass differed
/// every time (the header and both kept pages were rebuilt at each category switch on a busy Mac).
@MainActor
struct MarketPassedTests {
    private static func bytes<Value>(_ value: Value) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    /// A pass of `MarketView`'s body: new arrays and closures that hold something of their own, as the body makes them.
    private static func header(_ tab: MarketTab, boxes: MarketPassedBoxes, search: MarketSearch) -> MarketHeader {
        let token = NSObject()
        let facts = MarketHeaderFacts(
            tab: tab, tabs: MarketTab.available { _ in true }, supported: true, sharingSupported: true, search: search)
        let calls = MarketHeaderCalls(
            onTab: { _ in _ = token }, onImport: { _ = token }, onOwn: { _ = token }, onMine: { _ = token })
        let passed = boxes.pass("header", facts, calls)
        return MarketHeader(passed: passed, version: passed.version)
    }

    private static func page(_ key: String, boxes: MarketPassedBoxes) -> KeptMarketPage<Text> {
        let token = NSObject()
        let inputs = KeptMarketPageInputs(
            query: "", languageCode: String("en".reversed().reversed()), catalog: [], integrations: [], agents: [],
            canShare: true, error: nil)
        let passed = boxes.page("bots", KeptMarketPageFacts(shown: false, key: key, inputs: inputs)) {
            Text(token.description)
        }
        return KeptMarketPage(passed: passed, version: passed.version)
    }

    @Test func theHeaderIsTheSameBytesWhileItsFactsAre() {
        let boxes = MarketPassedBoxes()
        let search = MarketSearch()
        let first = Self.header(.services, boxes: boxes, search: search)
        let again = Self.header(.services, boxes: boxes, search: search)
        #expect(Self.bytes(first) == Self.bytes(again))
        #expect(first == again)
        let bots = Self.header(.bots, boxes: boxes, search: search)
        #expect(bots != again, "another page in front is another header")
        #expect(bots.passed.facts.tab == .bots)
    }

    @Test func aKeptPageIsTheSameBytesWhileItsFactsAre() {
        let boxes = MarketPassedBoxes()
        // A long key is a new string at each pass.
        let first = Self.page("bots|category:Developer tools", boxes: boxes)
        let again = Self.page("bots|category:" + "Developer tools", boxes: boxes)
        #expect(Self.bytes(first) == Self.bytes(again))
        #expect(first == again)
        let other = Self.page("bots|all", boxes: boxes)
        #expect(other != again, "a new filter of its own makes the page again")
    }

    private static let inputs = KeptMarketPageInputs(
        query: "", languageCode: "en", catalog: [], integrations: [], agents: [], canShare: false, error: nil)

    /// Every fact of a kept page makes it again when it changes; a pass with the same facts does not.
    @Test func aKeptPageVersionGrowsWithEachFact() {
        let catalog = [
            IntegrationCatalogEntry(
                id: "fetch", name: "Fetch", descriptionEn: "", descriptionRu: "", kind: .stdio, command: "uvx",
                docsUrl: "", icon: "", auth: .none)
        ]
        let base = KeptMarketPageFacts(shown: false, key: "bots|all", inputs: Self.inputs)
        var changes: [(String, KeptMarketPageFacts)] = []
        func with(_ name: String, _ change: (inout KeptMarketPageFacts) -> Void) {
            var facts = base
            change(&facts)
            changes.append((name, facts))
        }
        with("shown") { $0.shown = true }
        with("key") { $0.key = "bots|myBots" }
        with("query") { $0.inputs.query = "git" }
        with("languageCode") { $0.inputs.languageCode = "ru" }
        with("catalog") { $0.inputs.catalog = catalog }
        with("integrations") { $0.inputs.integrations = [Integration(id: "i", name: "x", kind: .http)] }
        with("agents") { $0.inputs.agents = [Agent(id: "a1", name: "Forge", runtime: .claude, cwd: "/work")] }
        with("canShare") { $0.inputs.canShare = true }
        with("error") { $0.inputs.error = UserFacingMessage(text: "No server") }
        for (name, facts) in changes {
            let boxes = MarketPassedBoxes()
            let first = boxes.page("bots", base) { Text("page") }
            let version = first.version
            _ = boxes.page("bots", base) { Text("page") }
            #expect(first.version == version, "the same facts keep the version (\(name))")
            let changed = boxes.page("bots", facts) { Text("page") }
            #expect(changed === first, "the same box (\(name))")
            #expect(changed.version == version + 1, "a new \(name) makes the page again")
        }
    }

    /// Every fact of the header makes it again when it changes; a pass with the same facts does not.
    @Test func theHeaderVersionGrowsWithEachFact() {
        let search = MarketSearch()
        let base = MarketHeaderFacts(
            tab: .services, tabs: [.services, .bots], supported: true, sharingSupported: false, search: search)
        let changes: [(String, MarketHeaderFacts)] = [
            ("tab", MarketHeaderFacts(tab: .bots, tabs: [.services, .bots], supported: true, sharingSupported: false, search: search)),
            ("tabs", MarketHeaderFacts(tab: .services, tabs: [.services], supported: true, sharingSupported: false, search: search)),
            ("supported", MarketHeaderFacts(tab: .services, tabs: [.services, .bots], supported: false, sharingSupported: false, search: search)),
            ("sharingSupported", MarketHeaderFacts(tab: .services, tabs: [.services, .bots], supported: true, sharingSupported: true, search: search)),
        ]
        let calls = MarketHeaderCalls(onTab: { _ in }, onImport: {}, onOwn: {}, onMine: {})
        for (name, facts) in changes {
            let boxes = MarketPassedBoxes()
            let first = boxes.pass("header", base, calls)
            let version = first.version
            _ = boxes.pass("header", base, calls)
            #expect(first.version == version, "the same facts keep the version (\(name))")
            _ = boxes.pass("header", facts, calls)
            #expect(first.version == version + 1, "a new \(name) makes the header again")
        }
    }

    /// A pass hands over its own closures even when the facts are the same: a control calls the newest.
    @Test func aPassReplacesTheCalls() {
        let boxes = MarketPassedBoxes()
        let facts = MarketHeaderFacts(
            tab: .services, tabs: [.services], supported: true, sharingSupported: false, search: MarketSearch())
        var called: [String] = []
        let box = boxes.pass(
            "header", facts,
            MarketHeaderCalls(onTab: { _ in called.append("old") }, onImport: { called.append("old") }, onOwn: {}, onMine: {}))
        _ = boxes.pass(
            "header", facts,
            MarketHeaderCalls(onTab: { _ in called.append("new") }, onImport: { called.append("new") }, onOwn: {}, onMine: {}))
        box.calls.onTab(.bots)
        box.calls.onImport()
        #expect(called == ["new", "new"])
        let page = boxes.page("bots", KeptMarketPageFacts(shown: true, key: "k", inputs: Self.inputs)) { Text("old") }
        _ = boxes.page("bots", KeptMarketPageFacts(shown: true, key: "k", inputs: Self.inputs)) { Text("new") }
        #expect(page.calls() == Text("new"))
    }

    /// The closures in a box hold `MarketView`, which holds the boxes: they are held weakly, by the view only.
    @Test func aBoxLivesAsLongAsItsView() {
        let boxes = MarketPassedBoxes()
        weak var box: MarketPassed<MarketHeaderFacts, MarketHeaderCalls>?
        do {
            let header = Self.header(.services, boxes: boxes, search: MarketSearch())
            box = header.passed
            #expect(box != nil)
        }
        #expect(box == nil)
    }
}
#endif
