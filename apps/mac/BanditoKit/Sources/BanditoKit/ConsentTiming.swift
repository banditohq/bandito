import Foundation

/// When the first-run notice about statistics may cover the window. It must not close the first chat: after the
/// introduction it waits until the first reply of an agent is complete and the person is not typing, or until the next
/// launch, whichever comes first. A person who had no introduction to go through (it was done before this launch) sees it
/// at once, as before.
public enum ConsentTiming {
    public static func mayShow(
        introductionActive: Bool, introductionWasDoneAtLaunch: Bool, firstReplyDone: Bool, draftIsEmpty: Bool
    ) -> Bool {
        guard !introductionActive else { return false }
        if introductionWasDoneAtLaunch { return true }
        return firstReplyDone && draftIsEmpty
    }
}
