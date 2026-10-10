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
        if compact {
            compactBody
        } else {
            EmptyState(
                symbol: symbol, title: L10n.Empty.NoServers.title, message: L10n.Mode.connectServer,
                action: EmptyStateAction(L10n.Empty.NoServers.action) { router.sheet = .addServer })
        }
    }

    /// The sidebar version keeps its small layout: the full empty state is too large for a 296 pt column.
    private var compactBody: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.Bandito.text3)
            Text(L10n.Empty.NoServers.title)
                .font(BanditoFont.text(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Mode.connectServer)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
            Button(L10n.Empty.NoServers.action) {
                router.sheet = .addServer
            }
            .banditoButton(.signal())
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
