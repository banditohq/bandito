import BanditoDesign
import BanditoL10n
import SwiftUI

/// A modal panel inside the Marketplace page: a dimmed page and a `surface2` card in the middle. It stands in for a
/// system sheet where the panel must open other sheets (connecting a service, signing in in the browser): a sheet
/// cannot open a second one from the window behind it, a panel can.
///
/// Esc and a click outside close it, unless `canClose` is false (a create that is running).
struct MarketPanel<Content: View>: View {
    var width: CGFloat = 560
    var canClose = true
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .contentShape(Rectangle())
                .onTapGesture { if canClose { onClose() } }
                .accessibilityHidden(true)
            content
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.Bandito.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.Bandito.text.opacity(0.12), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
                .padding(24)
        }
        .background {
            // Esc closes the panel.
            Button("") { if canClose { onClose() } }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// The footer of a panel: a hairline above, the buttons on the right.
struct MarketPanelFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            HStack(spacing: 10) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }
}
