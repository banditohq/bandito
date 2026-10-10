import BanditoDesign
import BanditoL10n
import SwiftUI

/// The main window: the sidebar (296 pt) on the left and the current mode on the right.
/// Two-finger swipes go back and forward where that means something (see `SwipeRoute`) when that gesture is on.
struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(GestureSettings.self) private var gestures
    @Environment(AccountHub.self) private var hub
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(Keymap.self) private var keymap
    @Environment(\.scenePhase) private var scenePhase
    /// The swipe in progress, for the arrow at the edge of the main area.
    @State private var swipeProgress: SwipeProgress?

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
            .overlay { SwipeHint(progress: swipeProgress, symbol: swipeSymbol) }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color.Bandito.bg)
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: router.sidebarVisible)
        .onTwoFingerSwipe(
            isEnabled: gestures.isEnabled(.twoFingerSwipe),
            sensitivity: gestures.swipeSensitivity,
            canSwipe: { direction, overPage in canSwipe(direction, overBrowserPage: overPage) },
            onProgress: { swipeProgress = $0 },
            onCommit: { direction, overPage in perform(direction, overBrowserPage: overPage) })
        // ⌘0 (the keymap's "team home") works from every mode; the menu in BanditoCommands does not list it.
        .keymapShortcut("global.teamHome", keymap: keymap) { router.showTeamHome() }
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
        .overlay {
            if let viewer = router.imageViewer {
                ImageViewer(request: viewer)
                    .id(viewer.id)
                    .transition(.opacity)
            }
        }
        .banditoAnimation(.easeOut(duration: BanditoMotion.base), value: router.imageViewer != nil)
        .overlay(alignment: .bottom) {
            if let notice = router.rollbackNotice {
                RollbackToast(notice: notice) { router.rollbackNotice = nil }
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .banditoAnimation(BanditoMotion.ease, value: router.rollbackNotice?.id)
        .overlay(alignment: .bottom) {
            if let notice = router.botNotice {
                BotNoticeToast(notice: notice) { router.botNotice = nil }
                    .padding(.bottom, 18)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .banditoAnimation(BanditoMotion.ease, value: router.botNotice?.id)
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
        // The server in front: the workbench state of its agents is kept under it (see `Router.workbenchKey`).
        .onChange(of: app.currentServer?.id, initial: true) { _, id in
            router.frontServerID = id?.uuidString
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, hub.signedIn {
                Task { await hub.refreshPending() }
            }
        }
    }

    // MARK: swipes

    private func swipeAction(_ direction: SwipeDirection, overBrowserPage: Bool) -> SwipeAction {
        let hasAgent = app.currentServer.map { !$0.agents.isEmpty } ?? false
        let context = SwipeContext(
            overBrowserPage: overBrowserPage,
            chatOpen: router.mode == .team && hasAgent && !router.showsTeamHome,
            onTeamHome: router.mode == .team && router.showsTeamHome,
            hasAgent: hasAgent)
        return SwipeRoute.action(mode: router.mode, context: context, direction: direction)
    }

    private var browserModel: BrowserModel? {
        app.currentServer.map { BrowserStore.shared.model(for: $0) }
    }

    /// Whether the swipe has anywhere to go: a page with no earlier page, or Files at its first folder, shows no arrow.
    private func canSwipe(_ direction: SwipeDirection, overBrowserPage: Bool) -> Bool {
        switch swipeAction(direction, overBrowserPage: overBrowserPage) {
        case .none: false
        case .browserBack: browserModel?.canGoBack ?? false
        case .browserForward: browserModel?.canGoForward ?? false
        case .filesBack: router.canGoBack
        case .filesForward: router.canGoForward
        case .closeChat, .reopenLastAgent: true
        }
    }

    private func perform(_ direction: SwipeDirection, overBrowserPage: Bool) {
        switch swipeAction(direction, overBrowserPage: overBrowserPage) {
        case .none: break
        case .browserBack: Task { await browserModel?.goBack() }
        case .browserForward: Task { await browserModel?.goForward() }
        case .filesBack: router.back()
        case .filesForward: router.forward()
        case .closeChat: router.showTeamHome()
        case .reopenLastAgent: router.leaveTeamHome()
        }
    }

    private var swipeSymbol: String? {
        guard let progress = swipeProgress else { return nil }
        return swipeAction(progress.direction, overBrowserPage: progress.overBrowserPage).symbol
    }

    @ViewBuilder
    private func sheetView(for sheet: Sheet) -> some View {
        switch sheet {
        case .newAgent: NewAgentSheet()
        case .account: AccountSheet()
        case .addServer: AddServerSheet()
        case .importer: ImportSheet()
        case .schedule(let agentID, let existing):
            if let server = app.currentServer {
                ScheduleEditor(server: server, agentID: agentID, existing: existing)
            }
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
        .background { ContentBackdrop().ignoresSafeArea() }
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
        case .market: MarketView()
        case .server: ServerMode()
        }
    }
}

/// The main area's backdrop: the warm background, a faint signal glow hanging over the top edge, and a slight
/// darkening toward the bottom. Static: nothing here animates or redraws per frame.
private struct ContentBackdrop: View {
    var body: some View {
        ZStack {
            Color.Bandito.bg
            RadialGradient(
                colors: [Color.Bandito.signal.opacity(0.09), Color.Bandito.signal.opacity(0)],
                center: UnitPoint(x: 0.5, y: -0.05),
                startRadius: 0,
                endRadius: 700)
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom)
        }
    }
}

/// The arrow at the edge of the main area while a swipe is under way: it grows and brightens as the swipe nears the
/// distance that commits it, and says where the swipe goes (a page back, a folder back, the team home).
private struct SwipeHint: View {
    var progress: SwipeProgress?
    var symbol: String?

    var body: some View {
        if let progress, let symbol {
            let leading = progress.direction == .back
            HStack {
                if !leading { Spacer(minLength: 0) }
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(progress.fraction >= 1 ? Color.Bandito.signal : Color.Bandito.text)
                    .frame(width: 44, height: 44)
                    .background(Color.Bandito.surface2, in: Circle())
                    .overlay(Circle().stroke(Color.Bandito.text.opacity(0.12), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.25), radius: 8, y: 2)
                    .scaleEffect(0.6 + 0.4 * progress.fraction)
                    .opacity(min(1, progress.fraction * 1.5))
                    .padding(leading ? .leading : .trailing, 14)
                if leading { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
