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
}
