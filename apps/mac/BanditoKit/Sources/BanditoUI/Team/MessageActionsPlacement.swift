import SwiftUI

/// Where the action row of a message sits and how strongly it is drawn. Pure, so the rules can be tested without a view.
///
/// The row is a line of icons right under the bubble, on the bubble's edge: the agent's messages on the left, the
/// person's on the right. It never covers the text. Its place is reserved in the layout, so that showing it does not
/// move the thread.
enum MessageActionsPlacement {
    /// The edge of an icon in the row, and the height of the row.
    static let rowHeight: CGFloat = 28
    /// The gap between two messages once the row is in it, from the bubble's bottom to the next message's top.
    static let gapBetweenMessages: CGFloat = 28
    /// The spacing `ThreadItemsView` puts between rows. Keep in step with it.
    static let threadSpacing: CGFloat = 12
    /// The part of the gap the row keeps as layout space. The row is drawn over the rest of it.
    static let reservedBelow: CGFloat = gapBetweenMessages - threadSpacing

    /// The edge of the bubble the row hangs from: the agent's messages on the left, the person's on the right.
    static func edge(isUser: Bool) -> HorizontalAlignment {
        isUser ? .trailing : .leading
    }

    /// How strongly the row is drawn. Hover shows it in full, and so does an open popover or menu, unless the mouse is
    /// selecting text: a selection must not be interrupted by the row. The last agent message keeps a faint row, so its
    /// actions are one glance away, as in ChatGPT. Every other message hides it.
    static func opacity(
        hovering: Bool, open: Bool, selectingText: Bool, isUser: Bool, isLastAgent: Bool
    ) -> Double {
        if open || (hovering && !selectingText) { return 1 }
        if isLastAgent && !isUser { return 0.5 }
        return 0
    }
}
