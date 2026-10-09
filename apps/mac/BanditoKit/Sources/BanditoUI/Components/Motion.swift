import SwiftUI

/// How much the app animates, from Settings → Appearance and motion. `off` acts like Reduce Motion.
public enum MotionLevel: String, CaseIterable, Sendable {
    case full, less, off

    /// `UserDefaults` key of the chosen level.
    public static let storageKey = "motion.level"

    /// The level from storage. Unknown or missing values mean `full`.
    public init(stored: String?) {
        self = MotionLevel(rawValue: stored ?? "") ?? .full
    }

    /// Whether animations should be dropped, given the system's Reduce Motion setting.
    public func reducesMotion(systemReduceMotion: Bool) -> Bool {
        self == .off || systemReduceMotion
    }
}

/// Applies an animation to changes of `value`, and none when motion is reduced (Reduce Motion or "Off" in settings).
private struct BanditoAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    func body(content: Content) -> some View {
        let reduced = MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion)
        content.animation(reduced ? nil : animation, value: value)
    }
}

public extension View {
    /// Use instead of `.animation(_:value:)` in Bandito components so Reduce Motion and the app's own setting are respected.
    /// - Parameters:
    ///   - animation: Animation used when `value` changes and motion is not reduced.
    ///   - value: The value to watch for changes.
    func banditoAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(BanditoAnimationModifier(animation: animation, value: value))
    }
}
