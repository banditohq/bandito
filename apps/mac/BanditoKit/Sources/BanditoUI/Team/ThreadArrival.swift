import BanditoKit
import SwiftUI

/// Tells the messages that came in while the chat is open from the ones that were already there.
///
/// The baseline is the newest message `seq` read by the first history load (`settle`). A message with a larger `seq`
/// arrived live. Older pages, the window sliding and later refreshes never move the baseline, and the rows read it only
/// when they appear. A plain reference, not observed: nothing redraws when it is set.
@MainActor
final class ThreadArrival {
    private(set) var baseline: Int64?

    /// Sets the baseline once, from the items read so far. An empty thread has baseline 0: every message is new.
    func settle(_ items: [ThreadItem]) {
        guard baseline == nil else { return }
        baseline = items.compactMap(\.messageSeq).max() ?? 0
    }

    /// Whether a row with this message `seq` arrived live. A row without a `seq` (tools, approvals, notes) never does.
    func isLive(seq: Int64?) -> Bool {
        guard let baseline, let seq else { return false }
        return seq > baseline
    }

    /// The message `seq` of a row, when the row is a message a person can react to (see `ThreadItem.messageSeq`).
    static func seq(of row: ThreadRow) -> Int64? {
        if case .item(let item) = row { return item.messageSeq }
        return nil
    }
}

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
