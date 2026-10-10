import Foundation

/// How many views are attached to one server's browser (Browser mode, a workbench tab). The browser polls and keeps
/// its page connection while the count is above zero. Counted, not flagged: when a view leaves after another one has
/// attached (switching from a workbench tab to Browser mode), the leaving view must not stop the one that stays.
struct BrowserAttachments: Equatable, Sendable {
    private(set) var count = 0

    var isAttached: Bool { count > 0 }

    /// Counts one more view. `true` when this is the first one, so the caller starts the polling.
    mutating func attach() -> Bool {
        count += 1
        return count == 1
    }

    /// Counts one view less. `true` when none is left, so the caller stops the polling. A detach without an attach
    /// changes nothing.
    mutating func detach() -> Bool {
        guard count > 0 else { return false }
        count -= 1
        return count == 0
    }
}
