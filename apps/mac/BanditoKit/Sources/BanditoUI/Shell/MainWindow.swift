import BanditoDesign
import BanditoL10n
import SwiftUI

/// The main window: the sidebar (296 pt) on the left and the current mode on the right.
/// Two-finger swipes go back and forward between modes when that gesture is on.
struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(GestureSettings.self) private var gestures
    @Environment(AccountHub.self) private var hub
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(\.scenePhase) private var scenePhase
    /// Shown after a rollback from "What changed", with the undo.
    @State private var rollbackNotice: RollbackNotice?

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
            VStack(spacing: 0) {
                PendingDevicesBanner()
                ModeArea()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color.Bandito.bg)
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: router.sidebarVisible)
        .onTwoFingerSwipe(
            isEnabled: gestures.isEnabled(.twoFingerSwipe),
            sensitivity: gestures.swipeSensitivity,
            onBack: { router.back() },
            onForward: { router.forward() })
        // Adding a server may be in the middle of an install: a stray click must not cancel it (Esc still closes).
        .banditoSheet(item: $router.sheet, dismissOnOutsideClick: router.sheet != .addServer) { sheet in
            sheetView(for: sheet)
        }
        .overlay {
            if router.paletteOpen {
                QuickOpenPalette()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = rollbackNotice {
                RollbackToast(notice: notice) { rollbackNotice = nil }
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .banditoAnimation(BanditoMotion.ease, value: rollbackNotice?.id)
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            if onboarding.tourRequested {
                TourLayer(anchors: anchors)
            }
        }
        .task {
            // Only with a session: without one nobody can ask for pending devices, and no device key is needed yet.
            guard hub.signedIn else { return }
            try? await hub.prepare()
            await hub.refreshPending()
            hub.startWatchingPending()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, hub.signedIn {
                Task { await hub.refreshPending() }
            }
        }
    }

    @ViewBuilder
    private func sheetView(for sheet: Sheet) -> some View {
        switch sheet {
        case .newAgent: NewAgentSheet()
        case .changes(let agentID): ChangesSheet(agentID: agentID) { rollbackNotice = $0 }
        case .account: AccountSheet()
        case .addServer: AddServerSheet()
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
