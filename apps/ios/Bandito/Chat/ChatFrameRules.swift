import CoreGraphics
import Foundation

/// Where the chat's list and message box sit. Pure.
///
/// The box is always on the bottom edge (above the home indicator, or above the keyboard when there is one) and the list
/// has the rest of the screen under the header. These are plain frames, not Auto Layout between two views: a layout that
/// is left to constraints can give the free space to the box (an empty list once showed the box under the header), and a
/// keyboard frame that the system gets wrong for a moment (a screenshot, a trait change, a send) must not carry the box
/// up with it.
struct ChatFrames: Equatable {
    var list: CGRect
    var box: CGRect
}

enum ChatFrameRules {
    /// The list keeps at least this much room, or a quarter of what is left when that is less (a keyboard in landscape).
    static let listFloor: CGFloat = 120

    /// - Parameters:
    ///   - size: the chat view's size.
    ///   - safeTop: the top inset (nothing in the app's chat, the bar is above the view).
    ///   - safeBottom: the home indicator's inset.
    ///   - keyboardTop: where the keyboard's top edge is, in the view's coordinates; nil when there is none.
    ///   - boxHeight: the height the box needs.
    static func frames(size: CGSize, safeTop: CGFloat, safeBottom: CGFloat, keyboardTop: CGFloat?, boxHeight: CGFloat) -> ChatFrames {
        let width = max(0, size.width.isFinite ? size.width : 0)
        let height = max(0, size.height.isFinite ? size.height : 0)
        let top = min(max(0, safeTop.isFinite ? safeTop : 0), height)
        let inset = min(max(0, safeBottom.isFinite ? safeBottom : 0), height)
        let room = max(0, height - top)
        // A box taller than the room is cut to it: the list may then be empty, but the box stays on the screen.
        let box = min(max(0, boxHeight.isFinite ? boxHeight : 0), room)
        let lowest = height - inset
        var bottom = lowest
        if let keyboardTop, keyboardTop.isFinite { bottom = min(lowest, keyboardTop) }
        // The list's floor holds the box down: a keyboard frame that is too high to be true is not followed.
        let listRoom = min(listFloor, max(0, room - box) * 0.25)
        let highest = min(lowest, top + listRoom + box)
        bottom = max(bottom, highest)
        bottom = max(bottom, top + box)
        let boxTop = bottom - box
        return ChatFrames(
            list: CGRect(x: 0, y: top, width: width, height: max(0, boxTop - top)),
            box: CGRect(x: 0, y: boxTop, width: width, height: box))
    }
}

/// When the person has seen the end of the chat, and so has read it. Pure.
enum ChatSeenRules {
    /// How far from the end the list may be and still count as at the end (the padding under the last row).
    static let slack: CGFloat = 40

    /// The end of the list is on the screen: it all fits, or the person is at the bottom.
    static func endIsVisible(contentHeight: CGFloat, offset: CGFloat, viewport: CGFloat) -> Bool {
        guard viewport > 0 else { return false }
        if contentHeight <= viewport + 0.5 { return true }
        return contentHeight - (offset + viewport) <= slack
    }

    /// The chat counts as read when it is on the screen of an active app and its end is seen, or when the person opened
    /// it at an entry (Activity) and so looked at what is in it.
    static func countsAsRead(visible: Bool, appActive: Bool, endVisible: Bool, openedAtEntry: Bool) -> Bool {
        guard visible, appActive else { return false }
        return endVisible || openedAtEntry
    }
}
