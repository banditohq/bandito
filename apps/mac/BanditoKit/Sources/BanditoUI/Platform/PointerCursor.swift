#if os(macOS)
import AppKit

/// The pointer shape for link-like buttons. Pushes and pops must balance; `PointingHandCursor` keeps them paired.
@MainActor
enum PointerCursor {
    static func pushPointingHand() {
        NSCursor.pointingHand.push()
    }

    static func pop() {
        NSCursor.pop()
    }
}
#else
@MainActor
enum PointerCursor {
    static func pushPointingHand() {}
    static func pop() {}
}
#endif
