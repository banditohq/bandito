import Testing

@testable import BanditoUI

#if os(macOS)
import AppKit
#endif

/// Typing with no field focused goes to the composer (`ComposerFocus.shouldRedirectTyping`).
@Suite struct ComposerTypingTests {
    private func redirects(
        _ characters: String, command: Bool = false, control: Bool = false, option: Bool = false,
        responder: ComposerFocus.Responder = .inert, modalOpen: Bool = false, chatShown: Bool = true
    ) -> Bool {
        ComposerFocus.shouldRedirectTyping(
            key: .init(characters: characters, command: command, control: control, option: option),
            responder: responder, modalOpen: modalOpen, chatShown: chatShown)
    }

    @Test func aLetterGoesToTheComposer() {
        #expect(redirects("a"))
        #expect(redirects("A"))
    }

    @Test func lettersOfOtherLayoutsAndSignsAndDigitsGo() {
        #expect(redirects("ы"))
        #expect(redirects("ß"))
        #expect(redirects("あ"))
        #expect(redirects("漢"))
        #expect(redirects("7"))
        #expect(redirects("/"))
        #expect(redirects("?"))
        #expect(redirects("😀"))
    }

    @Test func theSpaceGoes() {
        #expect(redirects(" "))
    }

    @Test func optionIsALayoutsWayToASign() {
        #expect(redirects("å", option: true))
        #expect(redirects("@", option: true))
    }

    @Test func commandAndControlAreShortcuts() {
        #expect(!redirects("c", command: true))
        #expect(!redirects("v", command: true))
        #expect(!redirects("a", control: true))
        #expect(!redirects("a", command: true, option: true))
        // A control press arrives as a control character too.
        #expect(!redirects("\u{1}", control: true))
    }

    @Test func arrowsFunctionKeysAndEditingKeysAreNotText() {
        #expect(!redirects("\u{F700}"))  // up
        #expect(!redirects("\u{F701}"))  // down
        #expect(!redirects("\u{F702}"))  // left
        #expect(!redirects("\u{F703}"))  // right
        #expect(!redirects("\u{F704}"))  // F1
        #expect(!redirects("\u{F728}"))  // forward delete
        #expect(!redirects("\u{F729}"))  // home
        #expect(!redirects("\u{1B}"))  // Esc
        #expect(!redirects("\t"))  // Tab
        #expect(!redirects("\r"))  // Return
        #expect(!redirects("\u{3}"))  // Enter
        #expect(!redirects("\u{7F}"))  // Delete
        #expect(!redirects("\u{8}"))
    }

    @Test func aDeadKeyAndAnEmptyPressAreNotText() {
        #expect(!redirects(""))
    }

    @Test func aFieldOrAViewWithItsOwnKeysKeepsTheKeys() {
        #expect(!redirects("a", responder: .textInput))
        #expect(!redirects("a", responder: .other))
    }

    @Test func anOpenSheetPopoverOrViewerKeepsTheKeys() {
        #expect(!redirects("a", modalOpen: true))
        #expect(!redirects(" ", modalOpen: true))
    }

    @Test func nothingHappensWhenTheWindowIsNotAnAgentsChat() {
        #expect(!redirects("a", chatShown: false))
    }

    @Test func aMixedPressIsText() {
        // A long press or an input method can deliver more than one character in a press.
        #expect(ComposerFocus.isTypedText("ab"))
        #expect(!ComposerFocus.isTypedText("a\u{F700}"))
    }

    @Test func heldPressesComeOutInTheOrderTheyWereTyped() {
        var queue = TypeAheadQueue<String>()
        #expect(!queue.isWaiting)
        let first = queue.hold("h")
        let second = queue.hold("i")
        let third = queue.hold("!")
        #expect(first, "the first press asks for the focus")
        #expect(!second && !third, "the rest wait with it")
        #expect(queue.isWaiting)
        let released = queue.release()
        #expect(released == ["h", "i", "!"])
        #expect(!queue.isWaiting)
        let next = queue.hold("x")
        #expect(next, "after a release the next press asks again")
    }

    @Test func composerFocusRulesAreUnchanged() {
        #expect(ComposerFocus.shouldTakeFocus(reason: .agentOpened, otherFieldHasFocus: false))
        #expect(!ComposerFocus.shouldTakeFocus(reason: .agentOpened, otherFieldHasFocus: true))
        #expect(ComposerFocus.shouldTakeFocus(reason: .requested, otherFieldHasFocus: true))
        #expect(!ComposerFocus.shouldTakeFocus(reason: .feedUpdate, otherFieldHasFocus: false))
    }

    #if os(macOS)
    @MainActor @Test func theKeyboardIsToldFromItsHolder() {
        let editable = NSTextView(frame: .zero)
        editable.isEditable = true
        let readOnly = NSTextView(frame: .zero)
        readOnly.isEditable = false
        #expect(ComposerTypeAhead.classify(nil) == .inert)
        #expect(ComposerTypeAhead.classify(editable) == .textInput)
        #expect(ComposerTypeAhead.classify(NSTextField()) == .textInput)
        #expect(ComposerTypeAhead.classify(readOnly) == .inert, "a click on a message's text is not a field")
        #expect(ComposerTypeAhead.classify(NSTableView()) == .inert, "the thread and the sidebar are tables")
        #expect(ComposerTypeAhead.classify(NSScrollView()) == .inert)
        #expect(ComposerTypeAhead.classify(NSWindow()) == .inert)
        #expect(ComposerTypeAhead.classify(NSView()) == .other, "a terminal or a browser is a view of its own")
    }

    /// The whole path on a window nobody sees: a key typed with the keyboard on nothing is held, the field is asked for
    /// the keyboard, the caret goes after the draft, and the same press is given back and passes to the field.
    @MainActor @Test func aHeldPressIsGivenBackToTheFieldOnceItHasTheKeyboard() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        field.isEditable = true
        field.string = "draft"
        field.setSelectedRange(NSRange(location: 0, length: 5))
        content.addSubview(field)
        window.contentView = content
        window.makeFirstResponder(nil)

        let typeAhead = ComposerTypeAhead()
        typeAhead.window = { window }
        typeAhead.isEnabled = { true }
        typeAhead.chatShown = { true }
        typeAhead.modalOpen = { false }
        typeAhead.requiresKeyWindow = false
        var asked = 0
        var posted: [NSEvent] = []
        typeAhead.post = { posted.append($0) }
        typeAhead.requestFocus = {
            asked += 1
            window.makeFirstResponder(field)
        }
        func key(_ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
        }

        // A shortcut and an arrow are left alone.
        #expect(typeAhead.handle(try key("c", flags: .command)) != nil)
        #expect(typeAhead.handle(try key("\u{F700}")) != nil)
        #expect(asked == 0)

        // A letter is held, the field is asked, and the press comes back in front of the queue.
        let letter = try key("k")
        #expect(typeAhead.handle(letter) == nil)
        #expect(asked == 1)
        for _ in 0..<50 where typeAhead.queue.isWaiting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!typeAhead.queue.isWaiting)
        #expect(field.selectedRange() == NSRange(location: 5, length: 0), "typed after the draft, not over it")
        let back = try #require(posted.first)
        #expect(posted.count == 1 && back === letter, "the same press, given back once")
        // It passes the monitor once, and then the field has the keyboard, so a new press is not held.
        #expect(typeAhead.handle(back) != nil)
        #expect(typeAhead.handle(try key("m")) != nil)
        #expect(asked == 1)
        window.contentView = nil
    }
    #endif
}
