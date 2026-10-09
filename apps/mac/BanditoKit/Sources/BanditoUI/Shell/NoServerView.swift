import BanditoDesign
import BanditoL10n
import SwiftUI

/// What a mode shows when no server is connected: "No servers", what the mode needs, and the button that opens
/// "Add server" (`Sheet.addServer`). `compact` is the version for the sidebars.
struct NoServerView: View {
    let symbol: String
    var compact = false

    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: compact ? 8 : 14) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 22 : 34, weight: .regular))
                .foregroundStyle(Color.Bandito.text3)
            Text(L10n.Empty.NoServers.title)
                .font(.system(size: compact ? 13 : 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Mode.connectServer)
                .font(.system(size: compact ? 12 : 13))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
            Button(L10n.Empty.NoServers.action) {
                router.sheet = .addServer
            }
            .banditoButton(.signal())
            .padding(.top, compact ? 2 : 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
