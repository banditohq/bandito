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
            SidebarFooter()
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color.Bandito.surface1)
    }
}

/// 52 pt high, like the title bar. The traffic lights sit on the left; search and new agent on the right.
private struct SidebarTopRow: View {
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                router.paletteOpen = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(IconButtonStyle(size: 30, label: L10n.Palette.search))
            .help(L10n.Sidebar.search)

            Button {
                router.sheet = .newAgent
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle(size: 30, label: L10n.Sidebar.newAgent))
            .help(L10n.Sidebar.newAgent)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

/// The list under the mode bar. Switching modes cross-fades the lists.
private struct ModeSidebarContent: View {
    @Environment(Router.self) private var router

    var body: some View {
        ZStack {
            sidebar(for: router.mode)
                .id(router.mode)
                .transition(.opacity)
        }
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: router.mode)
    }

    @ViewBuilder
    private func sidebar(for mode: AppMode) -> some View {
        switch mode {
        case .team: TeamSidebar()
        case .files: FilesSidebar()
        case .terminals: TerminalsSidebar()
        case .browser: BrowserSidebar()
        case .screen: ScreenSidebar()
        case .server: ServerSidebar()
        }
    }
}
