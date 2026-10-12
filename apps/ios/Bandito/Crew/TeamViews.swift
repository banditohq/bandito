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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.display(size: 14, weight: 600))
            .foregroundStyle(Color.Bandito.bg)
            .padding(.horizontal, 22)
            .frame(height: 46)
            .background(Capsule().fill(Color.Bandito.text))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// The connect flow is not built yet: this sheet only shows where it will live.
struct ConnectPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: BanditoSpace.s4) {
                Image("Raccoon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(L10n.Ios.Connect.placeholder)
                    .font(BanditoFont.text(size: 15))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
            }
            .padding(BanditoSpace.s6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Bandito.bg.ignoresSafeArea())
            .navigationTitle(L10n.Server.Add.heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.close) { dismiss() }
                }
            }
        }
    }
}
