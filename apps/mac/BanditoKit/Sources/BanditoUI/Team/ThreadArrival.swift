import BanditoKit
import SwiftUI

/// Entrance for a message that came in live: fades in and rises 6 pt in 0.22 s. A row that was already there is shown at
/// once: history, older pages and a window that slides never animate. With Reduce Motion, or "Off" in settings, every
/// row is shown at once.
struct LiveArrivalModifier: ViewModifier {
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    /// `live` is read once, when the row is made: the rows that were drawn before do not change their entrance.
    init(live: Bool) {
        _shown = State(initialValue: !live)
    }

    func body(content: Content) -> some View {
        let level = MotionLevel(stored: motionLevel)
        let still = level.reducesMotion(systemReduceMotion: reduceMotion)
        let visible = shown || still
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 6)
            .onAppear {
                guard !shown else { return }
                if still {
                    shown = true
                    return
                }
                withAnimation(.easeOut(duration: level.scaled(0.22))) {
                    shown = true
                }
            }
    }
}
