#if os(macOS)
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
