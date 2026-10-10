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

/// Centered empty state: a soft signal glow in a ring with a symbol, a title, an optional message and an optional
/// action. It fades in and grows from 96% with a spring, which `banditoAnimation` drops under Reduce Motion.
public struct EmptyState: View {
    public let symbol: String
    public let title: String
    public let message: String?
    public let action: EmptyStateAction?

    @State private var appeared = false

    public init(symbol: String, title: String, message: String? = nil, action: EmptyStateAction? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 0) {
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
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.Bandito.text2)
            }
            .frame(width: 88, height: 88)
            .accessibilityHidden(true)
            .padding(.bottom, 18)

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.system(size: 13))
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
}
