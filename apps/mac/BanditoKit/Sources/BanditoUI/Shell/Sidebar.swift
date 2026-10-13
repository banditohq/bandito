import BanditoDesign
import BanditoL10n
import SwiftUI

/// Left column of the main window, 296 pt wide: the top row (room for the traffic lights, search, new),
/// the server, the mode bar, the list of the current mode, and the footer.
struct Sidebar: View {
    static let width: CGFloat = 296

    var body: some View {
        VStack(spacing: 0) {
            SidebarTopRow()
            ServerPicker()
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            ModeBar()
            ModeSidebarContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            UpdateBannerSlot()
            SidebarFooter()
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // The title strip runs over the whole top of the column, under the traffic lights too. It is drawn before the
        // surface, so the surface does not cover it.
        .titleBarBand()
        .background(Color.Bandito.surface1)
    }
}

/// 52 pt high, like the title bar. The traffic lights sit on the left, then the brand; the empty space of the row
/// (between the brand and the buttons, and around them) zooms the window on a double-click and moves it on a drag.
/// Search and new agent sit on the right and keep their own clicks.
private struct SidebarTopRow: View {
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 8) {
            // Room for the traffic lights. The brand does nothing when clicked.
            HStack(spacing: 7) {
                RaccoonAvatar(name: "Bandito", color: .peach, face: .chevronDash, size: 22)
                Text(L10n.App.name)
                    .font(BanditoFont.text(size: 16, weight: 650))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 62)
            .accessibilityElement(children: .combine)
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button {
                router.paletteOpen = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .banditoButton(.icon(size: 30, label: L10n.Palette.search))
            .focusable(false)
            .help(L10n.Sidebar.search)

            Button {
                router.sheet = .newAgent
            } label: {
                Image(systemName: "plus")
            }
            .banditoButton(.icon(size: 30, label: L10n.Sidebar.newAgent))
            .focusable(false)
            .help(L10n.Sidebar.newAgent)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

/// The list under the mode bar. Switching modes cross-fades the lists.
private struct ModeSidebarContent: View {
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            let front = app.currentServer?.id.uuidString
            ForEach(TeamKeeping.built(kept: router.teamServers, front: front, teamShown: router.mode == .team), id: \.self) {
                serverID in
                TeamSidebar(serverID: serverID)
                    .keptMode(hidden: router.mode != .team || serverID != front)
            }
            if router.mode != .team {
                sidebar(for: router.mode)
                    .id(router.mode)
                    .transition(.opacity)
            }
        }
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: router.mode)
    }

    @ViewBuilder
    private func sidebar(for mode: AppMode) -> some View {
        switch mode {
        case .team: TeamSidebar(serverID: app.currentServer?.id.uuidString)
        case .files: FilesSidebar()
        case .terminals: TerminalsSidebar()
        case .browser: BrowserSidebar()
        case .screen: ScreenSidebar()
        case .market: MarketSidebar()
        case .server: ServerSidebar()
        }
    }
}
