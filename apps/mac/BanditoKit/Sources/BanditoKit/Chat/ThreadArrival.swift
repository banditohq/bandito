import Foundation

/// Tells the messages that came in while the chat is open from the ones that were already there.
///
/// The baseline is the newest message `seq` read by the first history load (`settle`). A message with a larger `seq`
/// arrived live. Older pages, the window sliding and later refreshes never move the baseline, and the rows read it only
/// when they appear. A plain reference, not observed: nothing redraws when it is set.
@MainActor
public final class ThreadArrival {
    public init() {}

    public private(set) var baseline: Int64?

    /// Sets the baseline once, from the items read so far. An empty thread has baseline 0: every message is new.
    public func settle(_ items: [ThreadItem]) {
        guard baseline == nil else { return }
        baseline = items.compactMap(\.messageSeq).max() ?? 0
    }

    /// Whether a row with this message `seq` arrived live. A row without a `seq` (tools, approvals, notes) never does.
    public func isLive(seq: Int64?) -> Bool {
        guard let baseline, let seq else { return false }
        return seq > baseline
    }

    /// The message `seq` of a row, when the row is a message a person can react to (see `ThreadItem.messageSeq`).
    public static func seq(of row: ThreadRow) -> Int64? {
        if case .item(let item) = row { return item.messageSeq }
        return nil
    }
}
