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
        typeAhead.composerReady = { true }
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

    /// A type-ahead on a window nobody sees, with an inert keyboard (the keyboard is on nothing).
    @MainActor private func makeTypeAhead(ready: Bool, takesFocus: Bool) -> (
        typeAhead: ComposerTypeAhead, window: NSWindow, key: (String, NSEvent.ModifierFlags) -> NSEvent, log: TypeAheadLog
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        field.isEditable = true
        content.addSubview(field)
        window.contentView = content
        window.makeFirstResponder(nil)
        let log = TypeAheadLog()
        let typeAhead = ComposerTypeAhead()
        typeAhead.window = { window }
        typeAhead.isEnabled = { true }
        typeAhead.chatShown = { true }
        typeAhead.requiresKeyWindow = false
        typeAhead.composerReady = { ready }
        typeAhead.requestFocus = {
            log.asked += 1
            if takesFocus { window.makeFirstResponder(field) }
        }
        typeAhead.cancelFocusRequest = { log.cancelled += 1 }
        typeAhead.post = { log.posted.append($0) }
        let make: (String, NSEvent.ModifierFlags) -> NSEvent = { characters, flags in
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
        }
        return (typeAhead, window, make, log)
    }

    @MainActor final class TypeAheadLog {
        var asked = 0
        var cancelled = 0
        var posted: [NSEvent] = []
    }

    @MainActor @Test func withoutAComposerThePressPassesAtOnceAndNothingIsRequested() {
        let setup = makeTypeAhead(ready: false, takesFocus: true)
        let letter = setup.key("k", [])
        #expect(setup.typeAhead.handle(letter) === letter, "the press goes where it was going")
        #expect(!setup.typeAhead.queue.isWaiting)
        #expect(setup.log.asked == 0, "no focus is asked of a composer that is not there")
        #expect(setup.log.posted.isEmpty)
    }

    @MainActor @Test func aComposerThatDoesNotTakeTheKeyboardHasItsRequestWithdrawnAndTheKeysGivenBack() async throws {
        let setup = makeTypeAhead(ready: true, takesFocus: false)
        let letter = setup.key("k", [])
        #expect(setup.typeAhead.handle(letter) == nil)
        #expect(setup.log.asked == 1)
        for _ in 0..<100 where setup.typeAhead.queue.isWaiting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!setup.typeAhead.queue.isWaiting)
        #expect(setup.log.cancelled == 1, "the request does not stay to take the keyboard later, unasked")
        #expect(setup.log.posted.count == 1 && setup.log.posted.first === letter)
    }

    @MainActor @Test func aKeyThatTakesTheKeyboardDoesNotWithdrawAnything() async throws {
        let setup = makeTypeAhead(ready: true, takesFocus: true)
        #expect(setup.typeAhead.handle(setup.key("k", [])) == nil)
        for _ in 0..<100 where setup.typeAhead.queue.isWaiting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(setup.log.cancelled == 0)
        #expect(setup.log.posted.count == 1)
    }

    @MainActor @Test func keysThatComeWhileALetterWaitsStayBehindItInOrder() async throws {
        let setup = makeTypeAhead(ready: true, takesFocus: true)
        let letter = setup.key("a", [])
        let enter = setup.key("\r", [])
        let arrow = setup.key("\u{F702}", [])
        let paste = setup.key("v", .command)
        #expect(setup.typeAhead.handle(letter) == nil)
        #expect(setup.typeAhead.handle(enter) == nil, "Return does not overtake the letter")
        #expect(setup.typeAhead.handle(arrow) == nil)
        #expect(setup.typeAhead.handle(paste) == nil)
        #expect(setup.log.asked == 1, "one request for the whole run")
        for _ in 0..<100 where setup.typeAhead.queue.isWaiting {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Given back last first, each at the front: the app then takes them as they were typed.
        #expect(setup.log.posted.count == 4)
        #expect(setup.log.posted.reversed().elementsEqual([letter, enter, arrow, paste], by: ===))
    }

    @MainActor @Test func aKeyTypedAfterTheQueueIsEmptyIsNotHeldWhenTheFieldHasTheKeyboard() async throws {
        let setup = makeTypeAhead(ready: true, takesFocus: true)
        #expect(setup.typeAhead.handle(setup.key("a", [])) == nil)
        for _ in 0..<100 where setup.typeAhead.queue.isWaiting {
            try await Task.sleep(for: .milliseconds(10))
        }
        let enter = setup.key("\r", [])
        #expect(setup.typeAhead.handle(enter) === enter, "the field has the keyboard now: Return is its own")
    }
    #endif
}
