import BanditoDesign
import BanditoL10n
import SwiftUI

/// What a mode shows while there is no server to show it for: its icon, its name and a hint to connect one.
struct ModePlaceholder: View {
    var mode: AppMode

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.Bandito.text3)
            Text(mode.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Mode.connectServer)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
    }
}

/// Sidebar stand-in for a mode whose list needs a server.
struct SidebarPlaceholder: View {
    var mode: AppMode

    var body: some View {
        VStack(spacing: 6) {
            Text(mode.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Bandito.text2)
            Text(L10n.Mode.connectServer)
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.surface1)
    }
}
