import BanditoDesign
import BanditoL10n
import SwiftUI

/// Bottom of the sidebar: the user's avatar, the apps button (not built yet), and the usage button.
struct SidebarFooter: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.Bandito.surface3))
                .accessibilityLabel(L10n.Profile.settings)

            Button {
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 13))
                    Text(L10n.Sidebar.connectApps)
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(Color.Bandito.text2)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Capsule().fill(Color.Bandito.text.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Color.Bandito.text.opacity(0.10)))
            }
            .banditoButton(.row(cornerRadius: 17))
            .disabled(true)

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
