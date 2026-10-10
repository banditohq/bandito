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
        let model = ScreenStore.shared.model(for: server)
        ScreenMainArea(model: model)
            .task(id: server.id) {
                model.attach()
            }
            .onDisappear {
                model.detach()
            }
    }
}

private struct ScreenMainArea: View {
    @Bindable var model: ScreenModel

    var body: some View {
        Group {
            if model.server.info == nil {
                ScreenNote(text: L10n.Screen.connecting)
            } else if !model.isSupported {
                ScreenUnsupported()
            } else {
                VStack(spacing: 0) {
                    ScreenToolbar(model: model)
                    ScreenCanvas(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.055, green: 0.047, blue: 0.043))
    }
}

// MARK: Toolbar

private struct ScreenToolbar: View {
    @Bindable var model: ScreenModel
    @Environment(Keymap.self) private var keymap

    var body: some View {
        let holder = model.status?.controller ?? .none
        HStack(spacing: 10) {
            Text(L10n.Screen.shared)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
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
                    .font(.system(size: 12, design: .monospaced))
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
        if model.status?.running == true, model.connection != nil {
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
        } else if model.status?.running == true {
            if let errorText = model.errorText {
                UserFacingErrorView(message: errorText)
                    .padding(16)
            } else {
                ScreenNote(text: L10n.Screen.connecting)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "display")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.Bandito.text3)
                Text(L10n.Screen.asleep)
                    .font(.system(size: 13))
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 0)
            }
            if model.asksToTakeControl {
                Text(L10n.Screen.askTakeControl)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.signal)
            }
            Text(agent ? L10n.Screen.agentBusy : L10n.Screen.hint)
                .font(.system(size: 12))
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
            ScreenSidebarContent(model: ScreenStore.shared.model(for: server))
        } else if let os = app.currentServer?.info?.os, os != "linux" {
            // Not an old daemon: this system has no server screen. The main area says why; the sidebar stays empty.
            Color.clear
        } else {
            SidebarPlaceholder(mode: .screen)
        }
    }
}

private struct ScreenSidebarContent: View {
    @Bindable var model: ScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(L10n.Screen.workplaces)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)

            screenCard
                .padding(.horizontal, 8)

            SectionLabel(L10n.Screen.transfer)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 8)

            VStack(spacing: 12) {
                HStack {
                    Text(L10n.Screen.clipboard)
                        .font(.system(size: 13))
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
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text2)
                    Spacer(minLength: 8)
                    Text(qualityName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                }
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 12)

            Text(L10n.Screen.sleepHint)
                .font(.system(size: 12))
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

    /// The workplace screen: a thumbnail, its name, and the state of the connection.
    private var screenCard: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: [Color(red: 0.23, green: 0.16, blue: 0.1), Color(red: 0.11, green: 0.16, blue: 0.23)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 52, height: 34)
                .overlay {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(Color.Bandito.text.opacity(0.1))
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Screen.shared)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Screen.sharedSub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Spacer(minLength: 0)
            StatusDot(status: model.status?.running == true ? .idle : .offline, size: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.Bandito.signal.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(Color.Bandito.signal.opacity(0.25))
        }
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
        EmptyState(symbol: "display", title: L10n.Screen.unsupported, message: L10n.Screen.unsupportedText)
    }
}

private struct ScreenNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.Bandito.text3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
