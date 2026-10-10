import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

@MainActor
@Suite struct KeymapTests {
    /// A UserDefaults domain that no other test or the app can see.
    func isolatedDefaults() -> UserDefaults {
        let suite = "bandito.keymap-tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func binding(_ key: String, _ modifiers: KeyModifier...) -> KeyBinding {
        KeyBinding(key: key, modifiers: Set(modifiers))
    }

    @Test func defaultsFollowTheSpecTable() {
        let keymap = Keymap(defaults: isolatedDefaults())
        #expect(keymap.binding(for: "global.quickOpen") == binding("k", .command))
        #expect(keymap.binding(for: "global.mode.market") == binding("6", .command))
        #expect(keymap.binding(for: "global.mode.server") == binding("7", .command))
        #expect(keymap.binding(for: "global.newAgent") == binding("n", .command))
        #expect(keymap.binding(for: "global.back") == binding("[", .command))
        #expect(keymap.binding(for: "global.forward") == binding("]", .command))
        #expect(keymap.binding(for: "global.toggleSidebar") == binding("s", .control, .command))
        #expect(keymap.binding(for: "global.usage") == binding("u", .option, .command))
        #expect(keymap.binding(for: "global.settings") == binding(",", .command))
        #expect(keymap.binding(for: "team.previousAgent") == binding("↑", .option, .command))
        #expect(keymap.binding(for: "team.needsYou") == binding("a", .shift, .command))
        #expect(keymap.binding(for: "team.stop") == binding(".", .command))
        #expect(keymap.binding(for: "terminals.collapse") == binding("↓", .shift, .command))
        #expect(keymap.binding(for: "files.copyPath") == binding("c", .option, .command))
        #expect(keymap.binding(for: "viewer.save") == binding("s", .command))
        #expect(keymap.binding(for: "screen.sendCtrlAltDelete") == binding("delete", .control, .option))
    }

    @Test func commandIdsAreUnique() {
        // Ids are stored in the user's overrides; a duplicate would also crash the registry lookup.
        #expect(Set(Command.all.map(\.id)).count == Command.all.count)
        #expect(Command.find("global.quickOpen")?.title == L10n.Keys.quickOpen)
    }

    @Test func defaultsDoNotConflict() {
        let keymap = Keymap(defaults: isolatedDefaults())
        for command in Command.all {
            guard let value = command.defaultBinding else { continue }
            let found = keymap.conflicts(for: value, in: command.context, excluding: command.id)
            #expect(found.isEmpty, "\(command.id) clashes with \(found.map(\.id))")
        }
    }

    @Test func symbolsFollowMacOrder() {
        #expect(binding("s", .control, .command).symbols == "⌃⌘S")
        #expect(binding("delete", .control, .option).symbols == "⌃⌥⌫")
        #expect(binding("↑", .option, .command).symbols == "⌥⌘↑")
        #expect(binding("k", .command).keyboardShortcut != nil)
    }

    @Test func overrideAndResetPersistAcrossInstances() {
        let defaults = isolatedDefaults()
        let first = Keymap(defaults: defaults)
        first.set(binding("j", .command), for: "global.quickOpen")
        first.set(nil, for: "team.stop")

        let second = Keymap(defaults: defaults)
        #expect(second.binding(for: "global.quickOpen") == binding("j", .command))
        #expect(second.binding(for: "team.stop") == nil)
        #expect(second.isCustomized("global.quickOpen"))
        #expect(second.customizedCount == 2)

        second.reset("global.quickOpen")
        #expect(second.binding(for: "global.quickOpen") == binding("k", .command))

        let third = Keymap(defaults: defaults)
        #expect(third.binding(for: "global.quickOpen") == binding("k", .command))
        #expect(third.binding(for: "team.stop") == nil)
    }

    @Test func resetAllClearsEveryOverride() {
        let keymap = Keymap(defaults: isolatedDefaults())
        keymap.set(binding("j", .command), for: "global.quickOpen")
        keymap.resetAll()
        #expect(keymap.binding(for: "global.quickOpen") == binding("k", .command))
        #expect(keymap.customizedCount == 0)
    }

    @Test func conflictInsideOneContextIsReported() {
        let keymap = Keymap(defaults: isolatedDefaults())
        keymap.set(binding("n", .shift, .command), for: "files.open")
        let found = keymap.conflicts(for: binding("n", .shift, .command), in: .files, excluding: "files.open")
        #expect(found.map(\.id) == ["files.newFolder"])
    }

    @Test func globalBindingConflictsFromAnyContext() {
        let keymap = Keymap(defaults: isolatedDefaults())
        keymap.set(binding("k", .command), for: "team.stop")
        let found = keymap.conflicts(for: binding("k", .command), in: .team, excluding: "team.stop")
        #expect(found.contains { $0.id == "global.quickOpen" })
    }

    @Test func sameBindingInAnotherContextIsAllowed() {
        let keymap = Keymap(defaults: isolatedDefaults())
        // ⌘⇧D is "What changed" in Team and "Split horizontally" in Terminals.
        let found = keymap.conflicts(for: binding("d", .shift, .command), in: .terminals, excluding: "terminals.splitHorizontal")
        #expect(found.isEmpty)
    }

    @Test func vsCodePresetOverridesOnlyItsCommands() {
        let keymap = Keymap(defaults: isolatedDefaults())
        keymap.apply(preset: .vscode)
        #expect(keymap.binding(for: "global.quickOpen") == binding("p", .command))
        #expect(keymap.binding(for: "global.toggleSidebar") == binding("b", .command))
        #expect(keymap.binding(for: "global.usage") == binding("u", .option, .command))

        keymap.apply(preset: .bandito)
        #expect(keymap.binding(for: "global.quickOpen") == binding("k", .command))
        #expect(keymap.binding(for: "global.toggleSidebar") == binding("s", .control, .command))
    }

    @Test func slackPresetMovesAgentSwitchingToOptionArrows() {
        let keymap = Keymap(defaults: isolatedDefaults())
        keymap.apply(preset: .slack)
        #expect(keymap.binding(for: "team.previousAgent") == binding("↑", .option))
        #expect(keymap.binding(for: "team.nextAgent") == binding("↓", .option))
        #expect(keymap.binding(for: "global.quickOpen") == binding("k", .command))
    }

    @Test func exportThenImportRestoresOverrides() throws {
        let source = Keymap(defaults: isolatedDefaults())
        source.set(binding("j", .command), for: "global.quickOpen")
        let data = try source.exportData()

        let target = Keymap(defaults: isolatedDefaults())
        try target.importData(data)
        #expect(target.binding(for: "global.quickOpen") == binding("j", .command))
    }
}
