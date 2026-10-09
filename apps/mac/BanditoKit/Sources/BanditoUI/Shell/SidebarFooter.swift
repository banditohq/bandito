import BanditoDesign
import BanditoL10n
import SwiftUI

/// Bottom of the sidebar: the account button and the usage button. The account button opens the account sheet:
/// the account when someone is signed in, the sign-in when nobody is.
struct SidebarFooter: View {
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 8) {
            Button {
                router.sheet = .account
            } label: {
                Image(systemName: "person.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.Bandito.surface3))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.Settings.Nav.account)
            .accessibilityLabel(L10n.Settings.Nav.account)

            Spacer(minLength: 0)

            UsageButton()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.Bandito.text.opacity(0.06))
                .frame(height: 1)
        }
    }
}
