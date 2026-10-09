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

    /// "Less" runs every animation at half the duration.
    public var durationScale: Double { self == .less ? 0.5 : 1 }

    /// A duration in seconds at this level.
    public func scaled(_ seconds: Double) -> Double { seconds * durationScale }

    /// Whether repeating animations run: pulses, the floating of the status dots, idle blinking, the
    /// sparkline. "Less" and "Off" keep them still, so the screen shows their rest frame.
    public var allowsRepeatingMotion: Bool { self == .full }
}

/// Applies an animation to changes of `value`, and none when motion is reduced (Reduce Motion or "Off" in settings).
private struct BanditoAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    func body(content: Content) -> some View {
        let level = MotionLevel(stored: motionLevel)
        let reduced = level.reducesMotion(systemReduceMotion: reduceMotion)
        // Half duration for "Less": speed 2 runs the same curve twice as fast.
        let timed = level == .less ? animation.speed(1 / level.durationScale) : animation
        content.animation(reduced ? nil : timed, value: value)
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
