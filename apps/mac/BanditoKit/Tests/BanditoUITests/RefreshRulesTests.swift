import Testing

@testable import BanditoUI

/// ⌘R: what each screen re-reads, and the one shortcut it has.
@Suite struct RefreshRulesTests {
    @Test func eachScreenRereadsItsOwnData() {
        #expect(RefreshRules.reloads(for: .team) == [.thread])
        #expect(RefreshRules.reloads(for: .files) == [.folder])
        #expect(RefreshRules.reloads(for: .terminals) == [.terminals])
        #expect(RefreshRules.reloads(for: .browser) == [.browserPage])
    }

    @Test func screensWithNothingToRereadHaveNoReload() {
        #expect(RefreshRules.reloads(for: .screen).isEmpty)
        #expect(RefreshRules.reloads(for: .server).isEmpty)
    }

    @Test func refreshIsCommandR() {
        let binding = Command.find("global.refresh")?.defaultBinding
        #expect(binding == KeyBinding(key: "r", modifiers: [.command]))
        #expect(Command.find("browser.reload") == nil, "the browser's own reload is replaced by ⌘R")
    }
}
