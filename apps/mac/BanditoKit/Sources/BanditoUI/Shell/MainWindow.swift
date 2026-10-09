import BanditoDesign
import BanditoL10n
import SwiftUI

/// The main window: the sidebar (296 pt) on the left and the current mode on the right.
/// Two-finger swipes go back and forward between modes when that gesture is on.
struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(GestureSettings.self) private var gestures

    var body: some View {
        @Bindable var router = router
        HStack(spacing: 0) {
            if router.sidebarVisible {
                Sidebar()
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.Bandito.text.opacity(0.07)).frame(width: 1)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ModeArea()
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color.Bandito.bg)
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: router.sidebarVisible)
        .onTwoFingerSwipe(
            isEnabled: gestures.isEnabled(.twoFingerSwipe),
            sensitivity: gestures.swipeSensitivity,
            onBack: { router.back() },
            onForward: { router.forward() })
        .sheet(item: $router.sheet) { sheet in
            sheetView(for: sheet)
        }
        .overlay {
            if router.paletteOpen {
                QuickOpenPalette()
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func sheetView(for sheet: Sheet) -> some View {
        switch sheet {
        case .newAgent: NewAgentSheet()
        default: SheetPlaceholder(sheet: sheet)
        }
    }
}

/// The main area: the view of the current mode, cross-fading when the mode changes.
private struct ModeArea: View {
    @Environment(Router.self) private var router

    var body: some View {
        ZStack {
            modeView(for: router.mode)
                .id(router.mode)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: router.mode)
    }

    @ViewBuilder
    private func modeView(for mode: AppMode) -> some View {
        switch mode {
        case .team: TeamMode()
        case .files: FilesMode()
        case .terminals: TerminalsMode()
        case .browser: BrowserMode()
        case .screen: ScreenMode()
        case .server: ServerMode()
        }
    }
}

/// Stand-in for the sheets whose screens come later (what changed, add server, settings).
private struct SheetPlaceholder: View {
    var sheet: Sheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Mode.soonHere)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
            Button(L10n.Common.close) { dismiss() }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(28)
        .frame(minWidth: 420, minHeight: 240)
        .background(Color.Bandito.surface2)
    }

    private var title: String {
        switch sheet {
        case .newAgent: L10n.AgentSheet.title
        case .changes: L10n.Keys.whatChanged
        case .addServer: L10n.Profile.addServer
        case .settings: L10n.Settings.title
        }
    }
}
