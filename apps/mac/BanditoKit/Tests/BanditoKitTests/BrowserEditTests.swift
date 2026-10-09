import Foundation
import Testing

@testable import BanditoKit

@Suite struct BrowserEditTests {
    @Test func commandShortcutsMapToEditCommands() {
        #expect(BrowserEdit.shortcut(key: "a", command: true, shift: false) == .selectAll)
        #expect(BrowserEdit.shortcut(key: "c", command: true, shift: false) == .copy)
        #expect(BrowserEdit.shortcut(key: "x", command: true, shift: false) == .cut)
        #expect(BrowserEdit.shortcut(key: "v", command: true, shift: false) == .paste)
        #expect(BrowserEdit.shortcut(key: "z", command: true, shift: false) == .undo)
        #expect(BrowserEdit.shortcut(key: "z", command: true, shift: true) == .redo)
    }

    @Test func withoutCommandThereIsNoEdit() {
        #expect(BrowserEdit.shortcut(key: "a", command: false, shift: false) == nil)
        #expect(BrowserEdit.shortcut(key: "k", command: true, shift: false) == nil)
    }

    @Test func editParamsCarryTheCommandName() throws {
        let key = try #require(BrowserKeys.descriptor(keyCode: 0, characters: "a", modifiers: [.meta]))
        let command = CDPCommand.editing(.selectAll, key: key, modifiers: [.meta])
        #expect(command.method == "Input.dispatchKeyEvent")
        guard case .object(let params) = command.params else {
            Issue.record("params must be an object")
            return
        }
        #expect(params["type"] == .string("keyDown"))
        #expect(params["commands"] == .array([.string("selectAll")]))
        #expect(params["modifiers"] == .number(4))
        // No text: a shortcut must not type a character.
        #expect(params["text"] == nil)
    }

    @Test func pasteIsInsertTextNotACommand() {
        // Chrome's paste command reads its own clipboard, not the Mac one, so paste sends the text.
        #expect(BrowserEdit.paste.cdpCommandName == nil)
        #expect(BrowserEdit.copy.cdpCommandName == "copy")
        #expect(BrowserEdit.redo.cdpCommandName == "redo")
    }
}
