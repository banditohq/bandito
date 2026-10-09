import SwiftUI

/// Applies an animation to changes of `value`, and none when Reduce Motion is on.
private struct BanditoAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

public extension View {
    /// Use instead of `.animation(_:value:)` in Bandito components so Reduce Motion is respected.
    /// - Parameters:
    ///   - animation: Animation used when `value` changes and Reduce Motion is off.
    ///   - value: The value to watch for changes.
    func banditoAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(BanditoAnimationModifier(animation: animation, value: value))
    }
}
