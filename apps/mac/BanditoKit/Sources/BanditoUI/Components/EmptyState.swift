import BanditoDesign
import SwiftUI

/// The button under an empty state. It is the signal button, as in the other empty states.
public struct EmptyStateAction {
    public let title: String
    public let perform: () -> Void

    public init(_ title: String, perform: @escaping () -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// Centered empty state: the raccoon mascot on a soft signal glow, a title, an optional message and an optional action.
/// The mascot floats gently while the window is active and motion is allowed. Pass `mascot: nil` where a mascot does
/// not fit, and the `symbol` is drawn in a ring instead. It fades in and grows from 96% with a spring, which
/// `banditoAnimation` drops under Reduce Motion.
public struct EmptyState: View {
    public let symbol: String
    public let title: String
    public let message: String?
    public let action: EmptyStateAction?
    /// The mascot's expression, or nil to draw `symbol` in a ring instead.
    public let mascot: AvatarMood?

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    public init(
        symbol: String, title: String, message: String? = nil, action: EmptyStateAction? = nil,
        mascot: AvatarMood? = .idle
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
        self.mascot = mascot
    }

    /// The mascot floats only when motion is allowed and the window is the active one.
    private var floats: Bool {
        !reduceMotion && MotionLevel(stored: motionLevel).allowsRepeatingMotion && controlActiveState == .active
    }

    public var body: some View {
        VStack(spacing: 0) {
            visual
                .frame(height: 120)
                .padding(.bottom, 14)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            if let action {
                Button(action.title, action: action.perform)
                    .banditoButton(.signal())
                    .padding(.top, 16)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96)
        .banditoAnimation(.spring(response: 0.42, dampingFraction: 0.82), value: appeared)
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private var visual: some View {
        if let mascot {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.Bandito.signal.opacity(0.26), Color.Bandito.signal.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 90))
                    .frame(width: 180, height: 180)
                Floating(enabled: floats) {
                    RaccoonAvatar(name: "Bandito", color: .peach, size: 72, mood: mascot)
                }
            }
        } else {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.Bandito.signal.opacity(0.22), Color.Bandito.signal.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 44))
                Circle()
                    .strokeBorder(Color.Bandito.text.opacity(0.08), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.Bandito.text2)
            }
            .frame(width: 88, height: 88)
        }
    }
}

/// Moves its content up and down by 3 pt over 3.2 s (1.6 s each way, ease in and out). A `PhaseAnimator` runs the
/// loop, so nothing is computed per frame. Disabled, the content stays at rest.
private struct Floating<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        PhaseAnimator(enabled ? [CGFloat(-3), CGFloat(3)] : [CGFloat(0)]) { offset in
            content().offset(y: offset)
        } animation: { _ in
            .easeInOut(duration: 1.6)
        }
    }
}
