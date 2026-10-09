import Foundation
import Observation

/// Text size of the terminals, in points. One value for all panes, kept in UserDefaults.
public enum TerminalFontSize {
    public static let range: ClosedRange<Double> = 9...28
    public static let standard: Double = 12.5
    /// One ⌘+ or ⌘− step.
    public static let step: Double = 1
    public static let defaultsKey = "terminal.fontSize"

    public static func clamp(_ size: Double) -> Double {
        min(max(size, range.lowerBound), range.upperBound)
    }

    /// The size after a pinch: `magnification` is the change reported by the trackpad (0.1 is 10 % larger).
    public static func scaled(_ size: Double, by magnification: Double) -> Double {
        clamp(size * (1 + magnification))
    }
}

/// The shared terminal text size, stored in UserDefaults under `terminal.fontSize`.
@MainActor
@Observable
public final class TerminalFontStore {
    public private(set) var size: Double

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: TerminalFontSize.defaultsKey) as? Double
        size = TerminalFontSize.clamp(saved ?? TerminalFontSize.standard)
    }

    public func set(_ value: Double) {
        size = TerminalFontSize.clamp(value)
        defaults.set(size, forKey: TerminalFontSize.defaultsKey)
    }

    public func bigger() { set(size + TerminalFontSize.step) }

    public func smaller() { set(size - TerminalFontSize.step) }

    public func reset() { set(TerminalFontSize.standard) }
}
