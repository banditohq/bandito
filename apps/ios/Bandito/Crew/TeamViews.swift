import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The first screen of a person without a server: the raccoon, a welcome line and one action.
struct WelcomeView: View {
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: BanditoSpace.s5) {
            Spacer()
            Image("Raccoon")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            Text(L10n.Ios.Welcome.title)
                .font(BanditoFont.display(size: 24, weight: 700))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Text(L10n.Onboarding.Welcome.subtitle)
                .font(BanditoFont.text(size: 15))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
            Spacer()
            Button(action: onConnect) {
                HStack(spacing: BanditoSpace.s2) {
                    Circle()
                        .fill(Color.Bandito.signalFill)
                        .frame(width: 7, height: 7)
                    Text(L10n.Empty.NoServers.action)
                }
            }
            .buttonStyle(SignalButtonStyle())
        }
        .padding(BanditoSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg.ignoresSafeArea())
    }
}

/// The primary action: a cream capsule with an orange dot, as in the Mac app's `.signal` button. A small copy here
/// until the button styles move from BanditoUI into BanditoDesign.
struct SignalButtonStyle: ButtonStyle {
    /// The capsule takes the whole width it is offered (a stacked pair of answers), not its label's.
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.display(size: 14, weight: 600))
            .foregroundStyle(Color.Bandito.bg)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 22)
            .frame(minHeight: 46)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(Capsule().fill(Color.Bandito.text))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// The two answers of a card or a sheet: the quiet one and the main one (Signal). Side by side while both fit at this
/// type size; at the largest sizes one above the other, the main one first, both full width. A side-by-side pair broke
/// "Отклонить" letter by letter at XXXL.
struct AnswerPair: View {
    let quiet: String
    let main: String
    var quietID: String?
    var mainID: String?
    var disabled = false
    /// The main answer is on its way: its label gives way to a spinner of the same size (the buttons stay off).
    var mainBusy = false
    let quietAction: () -> Void
    let mainAction: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BanditoSpace.s3) {
                quietButton(fullWidth: false)
                mainButton(fullWidth: false)
            }
            VStack(spacing: BanditoSpace.s2) {
                mainButton(fullWidth: true)
                quietButton(fullWidth: true)
            }
        }
    }

    private func quietButton(fullWidth: Bool) -> some View {
        Button(quiet, action: quietAction)
            .buttonStyle(QuietButtonStyle(fullWidth: fullWidth))
            .disabled(disabled)
            .optionalAccessibilityIdentifier(quietID)
    }

    private func mainButton(fullWidth: Bool) -> some View {
        Button(action: mainAction) {
            Text(main)
                .opacity(mainBusy ? 0 : 1)
                .overlay {
                    if mainBusy {
                        ProgressView()
                            .tint(Color.Bandito.bg)
                    }
                }
        }
        .buttonStyle(SignalButtonStyle(fullWidth: fullWidth))
        .disabled(disabled || mainBusy)
        .optionalAccessibilityIdentifier(mainID)
    }
}

private extension View {
    /// The identifier when one is given (the UI tests find a button by it); none otherwise, never the title.
    @ViewBuilder func optionalAccessibilityIdentifier(_ id: String?) -> some View {
        if let id {
            accessibilityIdentifier(id)
        } else {
            self
        }
    }
}

/// A list row whose text stays readable at the largest type sizes. At normal sizes the leading view, the text and the
/// trailing view sit side by side. At accessibility sizes the leading and trailing views share the top line and the text
/// takes the full width below them, so it wraps instead of breaking word by word in a narrow column. The views are the
/// same in both; only their place moves.
struct AdaptiveRowLayout<Leading: View, Content: View, Trailing: View>: View {
    private let alignment: VerticalAlignment
    private let leading: Leading
    private let content: Content
    private let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var typeSize

    init(
        alignment: VerticalAlignment = .center,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.alignment = alignment
        self.leading = leading()
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: BanditoSpace.s2) {
                HStack(alignment: .top, spacing: BanditoSpace.s3) {
                    leading
                    Spacer(minLength: BanditoSpace.s2)
                    trailing
                }
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(alignment: alignment, spacing: BanditoSpace.s3) {
                leading
                content
                Spacer(minLength: BanditoSpace.s2)
                trailing
            }
        }
    }
}
