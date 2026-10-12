import Foundation
import Testing

@testable import BanditoKit

@Suite struct BrowserTabsWireTests {
    @Test func aTabAnAgentOpenedDecodesWithItsFlag() throws {
        let json = Data(#"[{"id":"A1","type":"page","title":"Shop","url":"https://shop.example/","agent":true}]"#.utf8)
        let tabs = try JSONDecoder().decode([BrowserTab].self, from: json)
        #expect(tabs.count == 1)
        #expect(tabs[0].agent)
        #expect(tabs[0].id == "A1")
    }

    @Test func aTabWithoutTheFlagIsAPersonsTab() throws {
        // Older daemons, and a person's own tab on a new one, leave the flag out.
        let json = Data(#"[{"id":"P1","type":"page","title":"","url":"about:blank"}]"#.utf8)
        let tabs = try JSONDecoder().decode([BrowserTab].self, from: json)
        #expect(tabs[0].agent == false)
        #expect(tabs[0].isPage)
    }
}
