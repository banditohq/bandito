import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Server screen mode: the server's virtual desktop, shown over VNC. Waits for the server's info, says so
/// on a server that has no screen (macOS), and shows the example for it.
struct ScreenMode: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let server = app.currentServer {
            ScreenContent(server: server)
                .id(server.id)
        } else {
            ModePlaceholder(mode: .screen)
        }
    }
}

private struct ScreenContent: View {
    let server: ServerModel

    var body: some View {
        let selection = WorkspaceSelections.shared.selection(mode: "screen", server: server)
        ScreenWorkspaceArea(server: server, selection: selection)
    }
}

/// The screen of the chosen workplace. Choosing another one detaches the screen shown (its VNC connection closes) and
/// attaches the other; the sidebar and the mode do not rebuild, only the area that shows the picture does.
private struct ScreenWorkspaceArea: View {
    let server: ServerModel
    let selection: WorkspaceSelection

    var body: some View {
        let workspaceID = selection.selectedID
        let model = ScreenStore.shared.model(for: server, workspace: workspaceID)
        ScreenMainArea(model: model, title: title)
            .id(workspaceID)
            .task(id: workspaceID) {
                model.attach()
            }
            .onChange(of: workspaceID) { old, _ in
                ScreenStore.shared.model(for: server, workspace: old).detach()
            }
            .onDisappear {
                model.detach()
            }
            // The list of workplaces: read now and every few seconds while the mode is on screen.
            .task(id: server.id) {
                while !Task.isCancelled {
                    if selection.directory.shouldPoll { await selection.refresh() }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }

    private var title: String {
        guard let workspace = selection.selected, workspace.kind == .container else { return L10n.Screen.shared }
        return workspace.name
    }
}

private struct ScreenMainArea: View {
    @Bindable var model: ScreenModel
    /// The name of the workplace on the toolbar.
    let title: String

    var body: some View {
        Group {
            if model.server.info == nil {
                ScreenNote(text: L10n.Screen.connecting)
            } else if model.phase == .needsUpdate {
                // An older Linux daemon is fixed by an update; a Mac has no server screen at all.
                if model.server.info?.os == "linux" { ScreenNeedsUpdate() } else { ScreenUnsupported() }
            } else {
                VStack(spacing: 0) {
                    ScreenToolbar(model: model, title: title)
                    ScreenCanvas(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.055, green: 0.047, blue: 0.043))
    }
}

// MARK: Toolbar

struct ScreenToolbar: View {
    @Bindable var model: ScreenModel
    let title: String
    @Environment(Keymap.self) private var keymap
    /// Set while the "Put the screen to sleep" question is open.
    @State private var askingToSleep: ScreenSleepRules.Confirmation?

    var body: some View {
        let holder = model.status?.controller ?? .none
        HStack(spacing: 10) {
            Text(title)
                .font(BanditoFont.text(size: 14, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Spacer(minLength: 8)

            SegmentedPicker(
                selection: $model.quality,
                options: [
                    (ScreenQuality.auto, L10n.Screen.qualityAuto),
                    (ScreenQuality.faster, L10n.Screen.qualityFaster),
                    (ScreenQuality.sharper, L10n.Screen.qualitySharper),
                ]
            )
            .frame(width: 200)

            Button {
                model.sendCtrlAltDelete()
            } label: {
                Text(keymap.binding(for: "screen.sendCtrlAltDelete")?.symbols ?? "")
                    .font(BanditoFont.mono(size: 12, weight: 400))
            }
            .banditoButton(.quiet())
            .help(L10n.Screen.sendCAD)

            Button {
                WindowFullScreen.toggle()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .banditoButton(.icon(size: 30, label: L10n.Screen.fullscreen))
            .help(L10n.Screen.fullscreen)

            if model.status?.running == true {
                Button {
                    // Somebody holds the controls: ask first. A screen nobody holds goes to sleep at once.
                    if let confirmation = model.sleepConfirmation {
                        askingToSleep = confirmation
                    } else {
                        Task { await model.sleep() }
                    }
                } label: {
                    if model.isSleeping {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "moon.zzz")
                    }
                }
                .banditoButton(.icon(size: 30, label: L10n.Screen.sleep))
                .disabled(!model.canSleep)
                .help(L10n.Screen.sleep)
            }

            if holder == .user {
                Button(L10n.Browser.bannerGive) {
                    Task { await model.giveBack() }
                }
                .banditoButton(.quiet())
            } else {
                Button(L10n.Keys.takeControl) {
                    Task { await model.takeControl() }
                }
                .banditoButton(.lightPill())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .titleBarZoomOnDoubleClick()
        // The shortcuts come from the keymap, so a rebinding in Settings applies here too.
        .keymapShortcut("screen.sendCtrlAltDelete", keymap: keymap) { model.sendCtrlAltDelete() }
        .keymapShortcut("screen.takeControl", keymap: keymap) {
            Task {
                if model.status?.controller == .user {
                    await model.giveBack()
                } else {
                    await model.takeControl()
                }
            }
        }
        .background(Color(red: 0.07, green: 0.063, blue: 0.055))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
        .confirmationDialog(
            askingToSleep?.title ?? L10n.Screen.sleep,
            isPresented: Binding(get: { askingToSleep != nil }, set: { if !$0 { askingToSleep = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Screen.sleepConfirm, role: .destructive) {
                askingToSleep = nil
                Task { await model.sleep() }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Screen.sleepMessage)
        }
    }
}

// MARK: Canvas

private struct ScreenCanvas: View {
    @Bindable var model: ScreenModel
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            surface
                .scaleEffect(zoom)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            zoom = min(4, max(1, value.magnification))
                        }
                )
                .clipShape(RoundedRectangle(cornerRadius: BanditoRadius.md))
                .padding(16)

            if model.status?.running == true {
                WhoIsHere(model: model)
                    .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var surface: some View {
        switch model.phase {
        case .running:
            ZStack {
                #if os(macOS)
                VNCScreenView(model: model)
                #endif
                if model.isAgentControlling {
                    // The agent holds the screen: clicks and keys do not reach the VNC view.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.noteAgentHasControl() }
                }
                if !model.isConnected {
                    ScreenNote(text: L10n.Screen.connecting)
                        .background(Color(red: 0.09, green: 0.075, blue: 0.06))
                }
            }
        case .needsUpdate:
            ScreenNeedsUpdate()
        case .workplaceUnavailable:
            ScreenWorkplaceUnavailable()
        case .idle:
            ScreenAsleep(model: model)
        case .starting:
            ScreenProgress(text: L10n.Screen.starting)
        case .missingComponents(let names):
            ScreenMissingComponents(components: names, setup: model.setup) {
                Task { await model.installMissing() }
            }
        case .installing:
            ScreenInstalling(setup: model.setup)
        case .connecting:
            ScreenProgress(text: model.isSleeping ? L10n.Screen.sleeping : L10n.Screen.connecting)
        case .noFrame:
            ScreenFailure(message: UserFacingMessage(text: L10n.Screen.noFrame, canRetry: true)) {
                Task { await model.start() }
            }
        case .failed(let message):
            ScreenFailure(message: message) {
                Task { await model.start() }
            }
        }
    }
}

/// The screen is asleep: the start button. A failure of an earlier stop or refresh shows above it.
private struct ScreenAsleep: View {
    @Bindable var model: ScreenModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "display")
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            Text(L10n.Screen.asleep)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
            if let text = model.errorText {
                UserFacingErrorView(message: text)
                    .frame(maxWidth: 360)
            }
            Button(L10n.Screen.start) {
                Task { await model.start() }
            }
            .banditoButton(.signal())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The start is in flight, or the screen runs and its picture is on the way: a spinner in place of the button.
private struct ScreenProgress: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A start or a picture failed: the sentence, "Повторить" (which starts the screen again), and "Подробнее" with the
/// technical reason (`UserFacingErrorView`).
private struct ScreenFailure: View {
    let message: UserFacingMessage
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "display")
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            UserFacingErrorView(message: message, onRetry: retry)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The server lacks programs the screen needs. The sentence names them; "Установить" installs them (the install of
/// Server → Capabilities) and starts the screen again. The install's log, a password step and a failure show here too.
struct ScreenMissingComponents: View {
    let components: [String]
    @Bindable var setup: SetupModel
    let onInstall: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "display")
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Screen.missingComponents(components: components.joined(separator: ", ")))
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.Setup.install, action: onInstall)
                    .banditoButton(.signal())
                    .disabled(setup.isRunning)
                if let command = setup.passwordCommand {
                    SetupPasswordNote(command: command)
                }
                if let job = setup.job {
                    SetupJobPanel(setup: setup, job: job)
                }
                if let failed = setup.job?.failedComponent {
                    Text(L10n.Setup.failed(component: failed))
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = setup.error {
                    UserFacingErrorView(message: error)
                }
            }
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The install of the missing programs runs: a spinner and its log, in place of the screen.
struct ScreenInstalling: View {
    @Bindable var setup: SetupModel

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.Screen.installing)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
            if let job = setup.job {
                SetupJobPanel(setup: setup, job: job)
                    .frame(maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An older daemon on a Linux server: it has no screen feature. The update fixes it, so the page opens Server → Updates.
private struct ScreenNeedsUpdate: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "display")
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            Text(L10n.Screen.needsUpdate)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(L10n.Screen.openUpdates) {
                router.select(mode: .server)
                router.serverSection = .updates
            }
            .banditoButton(.signal())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The daemon does not know screens of separate workplaces (an older daemon). The update fixes it.
private struct ScreenWorkplaceUnavailable: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "display")
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            Text(L10n.Screen.workplaceUnavailable)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(L10n.Screen.openUpdates) {
                router.select(mode: .server)
                router.serverSection = .updates
            }
            .banditoButton(.signal())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The "Who is here" card: who holds the screen, and what a click does.
private struct WhoIsHere: View {
    @Bindable var model: ScreenModel

    var body: some View {
        let agent = model.isAgentControlling
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L10n.Screen.who)
            HStack(spacing: 9) {
                Circle()
                    .fill(agent ? Color.Bandito.info : Color.Bandito.surface3)
                    .frame(width: 8, height: 8)
                Text(agent ? L10n.Screen.agentControls : L10n.Screen.youWatch)
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 0)
            }
            if model.asksToTakeControl {
                Text(L10n.Screen.askTakeControl)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.signal)
            }
            Text(agent ? L10n.Screen.agentBusy : L10n.Screen.hint)
                .font(BanditoFont.text(size: 12, weight: 400))
                .lineSpacing(2)
                .foregroundStyle(Color.Bandito.text2)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(Color(red: 0.11, green: 0.094, blue: 0.082).opacity(0.92), in: RoundedRectangle(cornerRadius: BanditoRadius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: BanditoRadius.lg).strokeBorder(Color.Bandito.text.opacity(0.1))
        }
    }
}

// MARK: Sidebar

/// Screen sidebar: the workplace screens (one for now, "Shared"), the transfer options, and the sleep note.
struct ScreenSidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let server = app.currentServer, server.supports("screen") {
            ScreenSidebarContent(
                server: server, selection: WorkspaceSelections.shared.selection(mode: "screen", server: server))
        } else if let os = app.currentServer?.info?.os, os != "linux" {
            // Not an old daemon: this system has no server screen. The main area says why; the sidebar stays empty.
            Color.clear
        } else {
            SidebarPlaceholder(mode: .screen)
        }
    }
}

private struct ScreenSidebarContent: View {
    let server: ServerModel
    let selection: WorkspaceSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(L10n.Screen.workplaces)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 8)

                    ScreenCardList(server: server, selection: selection)
                        .padding(.horizontal, 8)

                    ScreenTransferSection(model: ScreenStore.shared.model(for: server, workspace: selection.selectedID))
                }
            }
            .scrollIndicators(.never)

            Text(L10n.Screen.sleepHint)
                .font(BanditoFont.text(size: 12, weight: 400))
                .lineSpacing(2)
                .foregroundStyle(Color.Bandito.text2)
                .padding(12)
                .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: BanditoRadius.lg))
                .overlay {
                    RoundedRectangle(cornerRadius: BanditoRadius.lg).strokeBorder(Color.Bandito.text.opacity(0.06))
                }
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.Bandito.surface1)
    }
}

/// A card for every workplace: its screen's preview and state. A click shows that screen in the main area. The states
/// of the other workplaces are read here, every few seconds, while the app is the active one.
private struct ScreenCardList: View {
    let server: ServerModel
    let selection: WorkspaceSelection

    var body: some View {
        let directory = selection.directory
        let overview = ScreenOverviews.shared.overview(for: server)
        // Before the list is read (or on a server without workplaces) the shared workplace alone is shown.
        let workspaces = directory.workspaces.isEmpty
            ? [Workspace(id: Workspace.sharedID, name: L10n.Workspace.Shared.title, kind: .shared)]
            : directory.workspaces
        let cards = ScreenCardData.make(
            workspaces: workspaces, states: overview.states, selectedID: selection.selectedID)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(cards) { card in
                ScreenCard(
                    data: card, preview: ScreenPreviews.shared.box(server: server.id, workspace: card.id),
                    onSelect: { selection.select(card.id) }
                )
                .equatable()
            }
        }
        .task(id: workspaces.map(\.id)) {
            while !Task.isCancelled {
                if AppActivity.isActive || overview.states.isEmpty { await overview.poll(workspaces) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// Clipboard and quality of the shown screen.
private struct ScreenTransferSection: View {
    @Bindable var model: ScreenModel

    var body: some View {
        SectionLabel(L10n.Screen.transfer)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 8)

        VStack(spacing: 12) {
            HStack {
                Text(L10n.Screen.clipboard)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                Spacer(minLength: 8)
                SegmentedPicker(
                    selection: $model.clipboard,
                    options: [
                        (ScreenClipboard.shared, L10n.Screen.clipboardShared),
                        (ScreenClipboard.off, L10n.Screen.clipboardOff),
                    ]
                )
                .frame(width: 150)
            }
            HStack {
                Text(L10n.Screen.quality)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                Spacer(minLength: 8)
                Text(qualityName)
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var qualityName: String {
        switch model.quality {
        case .auto: L10n.Screen.qualityAuto
        case .faster: L10n.Screen.qualityFaster
        case .sharper: L10n.Screen.qualitySharper
        }
    }
}

private struct ScreenUnsupported: View {
    var body: some View {
        EmptyState(
            symbol: "display", title: L10n.Screen.unsupported, message: L10n.Screen.unsupportedText, mascot: nil)
    }
}

private struct ScreenNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(BanditoFont.text(size: 13, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
