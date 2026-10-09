import BanditoDesign
import SwiftUI

/// How full a limit window is, by the share used. The one place where a used share becomes a colour: the sidebar
/// button, the usage popover and the menu bar all read it. Under 70% is fine, 70 to 90% is close, above 90% is over
/// (a window that is used up is 100%, so it is over too).
public enum UsageLevel: Hashable, Sendable {
    case ok, close, over

    public init(usedPercent: Int) {
        switch usedPercent {
        case ..<70: self = .ok
        case 70...90: self = .close
        default: self = .over
        }
    }

    /// Green under 70%, peach from 70% to 90%, red above 90%.
    public var color: Color {
        switch self {
        case .ok: Color.Bandito.ok
        case .close: BanditoPalette.peach
        case .over: Color.Bandito.danger
        }
    }
}
