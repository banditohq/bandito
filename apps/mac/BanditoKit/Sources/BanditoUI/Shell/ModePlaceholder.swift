import BanditoDesign
import BanditoL10n
import SwiftUI

/// What a mode shows while there is no server to show it for: "No servers" and the button to connect one.
struct ModePlaceholder: View {
    var mode: AppMode

    var body: some View {
        NoServerView(symbol: mode.systemImage)
            .background(Color.Bandito.bg)
    }
}

/// Sidebar stand-in for a mode whose list needs a server. Without a server it offers the connection; with an
/// old server it says that the server needs an update.
struct SidebarPlaceholder: View {
    var mode: AppMode

    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.currentServer == nil {
                NoServerView(symbol: mode.systemImage, compact: true)
            } else {
                VStack(spacing: 6) {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text2)
                    Text(L10n.Server.updateNote)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.surface1)
    }
}
