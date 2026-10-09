import BanditoDesign
import BanditoL10n
import SwiftUI

/// Stand-in for a mode whose screens are not built yet: its icon, its name and "Coming soon".
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
            Text(L10n.Mode.soonHere)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
    }
}

/// Sidebar stand-in for a mode whose list is not built yet.
struct SidebarPlaceholder: View {
    var mode: AppMode

    var body: some View {
        VStack(spacing: 6) {
            Text(mode.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Bandito.text2)
            Text(L10n.Mode.soonHere)
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.surface1)
    }
}
