import SwiftUI

extension EnvironmentValues {
    /// True inside a mode that is kept built while another mode shows (`KeptMode`).
    @Entry var modeHidden = false
}

/// A mode kept built while another one shows: invisible, out of hit testing, VoiceOver and the keyboard (its buttons
/// and fields are disabled, so their shortcuts do not fire and they cannot hold the focus). Building Team mode again at
/// each return cost 70–130 ms (its sidebar, its thread, its composer).
struct KeptMode: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            .disabled(hidden)
            .environment(\.modeHidden, hidden)
    }
}

extension View {
    func keptMode(hidden: Bool) -> some View { modifier(KeptMode(hidden: hidden)) }
}

/// Which servers' Team mode is kept built. Pure, for the tests.
enum TeamKeeping {
    /// `kept` with `serverID` moved (or added) to the end, the oldest dropped past `limit`.
    static func kept(_ kept: [String], adding serverID: String, limit: Int) -> [String] {
        var result = kept.filter { $0 != serverID }
        result.append(serverID)
        if result.count > limit { result.removeFirst(result.count - limit) }
        return result
    }

    /// The servers whose Team mode is in the window: the kept ones, and the one in front while Team mode shows (it
    /// joins the kept ones right after; a window with no server shows Team mode's empty state).
    static func built(kept: [String], front: String?, teamShown: Bool) -> [String?] {
        var result: [String?] = kept
        if teamShown, !kept.contains(where: { $0 == front }) { result.append(front) }
        return result
    }
}
