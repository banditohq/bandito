import SwiftUI

/// Entrance for list rows: fades in and rises 8 pt, once, when the row appears.
/// With Reduce Motion the row is shown at once. Apply it to list rows only, never to the cards inside them:
/// snapshots render without appearing, so a card that waits for `onAppear` would be blank.
public struct RiseInModifier: ViewModifier {
    var delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func body(content: Content) -> some View {
        let visible = shown || reduceMotion
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                withAnimation(.easeOut(duration: 0.35).delay(delay)) {
                    shown = true
                }
            }
    }
}

public extension View {
    /// Rise-in entrance for a list row. `delay` staggers rows that appear together.
    func banditoRise(delay: Double = 0) -> some View {
        modifier(RiseInModifier(delay: delay))
    }
}
