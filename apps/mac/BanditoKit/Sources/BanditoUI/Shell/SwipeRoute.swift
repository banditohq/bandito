import Foundation

/// Which way a two-finger swipe went: the fingers moving right is "back" (as in Safari), left is "forward".
enum SwipeDirection: Equatable {
    case back, forward
}

/// What a swipe does.
enum SwipeAction: Equatable {
    case none
    /// Back and forward in the history of the browser's page.
    case browserBack, browserForward
    /// Back and forward through the folders visited in Files.
    case filesBack, filesForward
    /// A chat closes and the team home shows.
    case closeChat
    /// The team home gives way to the chat it replaced.
    case reopenLastAgent

    /// The arrow shown while the swipe is in progress: where the page or the screen is going.
    var symbol: String? {
        switch self {
        case .none: nil
        case .browserBack, .filesBack, .closeChat: "chevron.left"
        case .browserForward, .filesForward, .reopenLastAgent: "chevron.right"
        }
    }
}

/// What the window knows about the place the swipe happens in.
struct SwipeContext: Equatable {
    /// The pointer is over a page of the shared browser (Browser mode, or a browser tab in the agent's panel).
    var overBrowserPage = false
    /// Team mode shows a chat.
    var chatOpen = false
    /// Team mode shows the team home.
    var onTeamHome = false
    /// The server has an agent whose chat the home can give way to.
    var hasAgent = false
}

/// What a two-finger swipe does where it happens. Pure, so the rules are easy to read and test. Swipes no longer step
/// through the modes: each place has its own meaning, and the rest do nothing.
enum SwipeRoute {
    static func action(mode: AppMode, context: SwipeContext, direction: SwipeDirection) -> SwipeAction {
        if context.overBrowserPage || mode == .browser {
            return direction == .back ? .browserBack : .browserForward
        }
        switch mode {
        case .files:
            return direction == .back ? .filesBack : .filesForward
        case .team:
            switch direction {
            case .back:
                return context.chatOpen && !context.onTeamHome ? .closeChat : .none
            case .forward:
                return context.onTeamHome && context.hasAgent ? .reopenLastAgent : .none
            }
        case .terminals, .screen, .market, .server, .browser:
            return .none
        }
    }
}
