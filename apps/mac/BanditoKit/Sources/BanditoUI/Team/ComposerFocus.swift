import Foundation

/// When the composer may take keyboard focus. It takes it only for something the person did: opening an agent, or
/// a request (⌘L, a click, Reply, the quick-open palette). A thread that changes (the agent thinks, a form arrives,
/// a message comes in) must never pull the focus back from a field the person is typing in.
enum ComposerFocus {
    enum Reason: Equatable {
        /// The thread of an agent was opened (the composer appeared).
        case agentOpened
        /// The person asked for it: a shortcut, a click, Reply, quick open.
        case requested
        /// The thread was updated: new rows, status, timers.
        case feedUpdate
    }

    /// `otherFieldHasFocus`: a text field other than the composer's is being edited (a form field, a search box).
    static func shouldTakeFocus(reason: Reason, otherFieldHasFocus: Bool) -> Bool {
        switch reason {
        case .requested: true
        case .agentOpened: !otherFieldHasFocus
        case .feedUpdate: false
        }
    }

    // MARK: Typing without a click

    /// What has the keyboard, as far as typing is concerned.
    enum Responder: Equatable {
        /// Nothing that takes text: the window, the thread, the sidebar, a message's read-only text. Typing may go to
        /// the composer.
        case inert
        /// A field or editor that takes text (a search box, a rename field, the composer itself, a sheet's field).
        case textInput
        /// A view with its own keys: the terminal, the browser, a custom control. Its keys are its own.
        case other
    }

    /// One key press, as far as the rule needs it.
    struct TypedKey: Equatable {
        /// What the key types (`NSEvent.characters`): the character in the layout in use, shifted or with ⌥.
        var characters: String
        var command = false
        var control = false
        var option = false

        init(characters: String, command: Bool = false, control: Bool = false, option: Bool = false) {
            self.characters = characters
            self.command = command
            self.control = control
            self.option = option
        }
    }

    /// Whether `characters` is text a person typed: letters of any layout, digits, signs and the space. Arrows, F-keys
    /// and the like come as private-use characters, Esc, Tab, Return and Delete as control characters; a dead key
    /// (⌥E before a vowel) comes as nothing. None of those is text.
    static func isTypedText(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .unassigned, .surrogate, .format, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }
    }

    /// Whether a key press that nothing took should move the keyboard to the composer and type there (as Telegram and
    /// Slack do). It does, when it is text without ⌘ or ⌃ (⌥ is a layout's way to a sign, so it is fine), the keyboard
    /// is on nothing that takes text or has keys of its own, no sheet, popover, viewer or palette is open, and the chat
    /// of an agent is what the window shows.
    static func shouldRedirectTyping(
        key: TypedKey, responder: Responder, modalOpen: Bool, chatShown: Bool
    ) -> Bool {
        guard chatShown, !modalOpen, responder == .inert else { return false }
        guard !key.command, !key.control else { return false }
        return isTypedText(key.characters)
    }
}

/// Key presses held back until the composer has the keyboard, then given to it in the order they came. Pure, so the order
/// is tested: the first press asks for the focus, the rest wait with it.
struct TypeAheadQueue<Event> {
    private(set) var held: [Event] = []

    var isWaiting: Bool { !held.isEmpty }

    /// Holds `event`. True for the first one: the caller asks for the focus then.
    mutating func hold(_ event: Event) -> Bool {
        held.append(event)
        return held.count == 1
    }

    /// The held presses in the order they were typed; the queue is empty after.
    mutating func release() -> [Event] {
        defer { held = [] }
        return held
    }
}
