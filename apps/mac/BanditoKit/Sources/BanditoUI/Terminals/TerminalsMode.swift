#if os(macOS)
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Terminals mode: the terminals on screen in the chosen layout, and the dock of collapsed ones below.
struct TerminalsMode: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let server = app.currentServer {
            TerminalsContent(server: server)
        } else {
            TerminalsPlaceholder(symbol: "terminal", title: L10n.Terminals.noServer, detail: nil, action: nil)
        }
    }
}

/// Connects the mode to the server's controller: loads the list, performs menu commands, and asks before
/// closing a terminal whose process is still running.
struct TerminalsContent: View {
    let server: ServerModel
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    /// The terminal the user is asked about before it is closed.
    @State private var closeCandidate: String?

    var body: some View {
        let controller = app.terminalController(for: server)
        Group {
            if !server.supports("terminals") {
                TerminalsPlaceholder(symbol: "terminal", title: L10n.Terminals.updateServer, detail: nil, action: nil)
            } else if !controller.isListed {
                TerminalsLoading(server: server)
            } else if controller.workspace.knownIDs.isEmpty {
                TerminalsPlaceholder(
                    symbol: "terminal", title: L10n.Terminals.empty, detail: L10n.Terminals.emptyHint,
                    action: { openNew(controller, split: false) })
            } else {
                TerminalArea(
                    controller: controller,
                    onNew: { openNew(controller, split: false) },
                    requestClose: { requestClose($0, controller: controller) })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x0E0C0B))
        .task(id: server.id) {
            await controller.start()
        }
        .onChange(of: router.terminalRequest) { _, request in
            guard let request else { return }
            router.terminalRequest = nil
            perform(request.action, controller: controller)
        }
        .onChange(of: router.pendingTerminalCommand, initial: true) { _, _ in
            guard let command = router.takeTerminalCommand() else { return }
            runInNewTerminal(command, controller: controller)
        }
        .confirmationDialog(
            L10n.Terminals.ConfirmClose.title,
            isPresented: Binding(get: { closeCandidate != nil }, set: { if !$0 { closeCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Terminals.ConfirmClose.end, role: .destructive) {
                if let id = closeCandidate {
                    Task { await controller.close(id) }
                }
            }
            Button(L10n.Terminals.ConfirmClose.cancel, role: .cancel) {}
        }
    }

    /// A new terminal: in the folder the Router was given (once), or the home folder. A split opens in the
    /// focused pane's folder instead.
    private func openNew(_ controller: TerminalController, split: Bool) {
        let cwd: String?
        if split {
            cwd = controller.focusedSession?.info.cwd
        } else {
            cwd = router.takeTerminalCwd()
        }
        Task { await controller.openNew(cwd: cwd, afterFocused: split) }
    }

    /// A new terminal that starts with a command typed into it (Server → Install, Update): the command goes in
    /// with a line break, so it runs as if the user typed it and pressed return.
    private func runInNewTerminal(_ command: String, controller: TerminalController) {
        Task {
            await controller.start()
            await controller.openNew(cwd: nil, afterFocused: false)
            guard let id = controller.workspace.focusedID else { return }
            try? await controller.server.input(Data((command + "\n").utf8), to: id)
        }
    }

    /// Closes at once when the process has ended; otherwise asks first.
    private func requestClose(_ id: String, controller: TerminalController) {
        if let info = controller.session(for: id)?.info, case .running = info.state {
            closeCandidate = id
        } else {
            Task { await controller.close(id) }
        }
    }

    private func perform(_ action: TerminalRequest.Action, controller: TerminalController) {
        let focused = controller.workspace.focusedID
        switch action {
        case .new:
            openNew(controller, split: false)
        case .splitVertical, .splitHorizontal:
            openNew(controller, split: true)
        case .collapse:
            if let focused { controller.collapse(focused) }
        case .restoreLast:
            controller.restoreLast()
        case .close:
            if let focused { requestClose(focused, controller: controller) }
        case .fullscreen:
            if let focused { controller.workspace.toggleFullscreen(focused) }
        case .clear:
            if let focused { controller.session(for: focused)?.clearScreen() }
        case .fontBigger:
            controller.font.bigger()
        case .fontSmaller:
            controller.font.smaller()
        case .fontReset:
            controller.font.reset()
        case .move(let direction):
            controller.workspace.move(direction)
        }
    }
}

/// The main area once the server's terminals are known: toolbar, grid of panes, dock.
struct TerminalArea: View {
    let controller: TerminalController
    let onNew: () -> Void
    let requestClose: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TerminalToolbar(controller: controller, onNew: onNew)
            if let notice = controller.notice {
                TerminalNoticeStrip(text: notice) { controller.clearNotice() }
            }
            TerminalGrid(controller: controller, requestClose: requestClose)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TerminalDock(controller: controller)
        }
        .onChange(of: controller.workspace.focusedID) { _, id in
            // Keyboard focus follows the focused pane, so typing goes where the orange frame is.
            guard let id, let view = controller.session(for: id)?.view else { return }
            if let window = view.window {
                window.makeFirstResponder(view)
            } else {
                view.wantsFocus = true
            }
        }
    }
}

/// 52 pt: the desktop name, the layout picker, "input to all" and "new terminal".
struct TerminalToolbar: View {
    let controller: TerminalController
    let onNew: () -> Void
    @Environment(Keymap.self) private var keymap

    var body: some View {
        let workspace = controller.workspace
        let inputToAll = workspace.inputToAll
        HStack(spacing: 10) {
            Text(desktopTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Text(L10n.Terminals.windowCount(count: workspace.onScreen.count))
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            Spacer(minLength: 12)
            Text(L10n.Terminals.layoutTitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            layoutPicker
            Button {
                workspace.inputToAll.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L10n.Terminals.inputToAll)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 11)
                .frame(height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(inputToAll ? BanditoPalette.peach : Color.Bandito.text2)
            .background(
                inputToAll ? Color.Bandito.signal.opacity(0.13) : Color.Bandito.text.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(inputToAll ? Color.Bandito.signal.opacity(0.4) : Color.Bandito.text.opacity(0.1))
            )
            .help(L10n.Terminals.inputToAllHint)
            .banditoAnimation(BanditoMotion.ease, value: inputToAll)

            Button(action: onNew) {
                Text(L10n.Keys.newTerminal)
            }
            .buttonStyle(SignalButtonStyle())
            .help(keymap.binding(for: "terminals.new")?.symbols ?? "")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color(hex: 0x12100E))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
    }

    private var desktopTitle: String {
        if let name = controller.focusedSession?.info.title, !name.isEmpty {
            return L10n.Terminals.desktop(name: name)
        }
        return L10n.Terminals.desktopDefault
    }

    private var layoutPicker: some View {
        let current = controller.workspace.layout
        return HStack(spacing: 2) {
            ForEach(TerminalLayout.allCases, id: \.self) { layout in
                Button {
                    controller.setLayout(layout)
                } label: {
                    Image(systemName: layout.systemImage)
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 34, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(layout == current ? Color.Bandito.text : Color.Bandito.text3)
                .background(
                    layout == current ? Color.Bandito.text.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .help(layout.title)
                .accessibilityLabel(layout.title)
            }
        }
        .padding(3)
        .background(Color.Bandito.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A one-line message above the grid. Tapping the cross dismisses it.
struct TerminalNoticeStrip: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(BanditoPalette.peach)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.Bandito.text3)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 30)
        .background(Color.Bandito.signal.opacity(0.08))
    }
}

/// Centered message for the states without panes: no server, an old server, nothing open yet, connecting.
struct TerminalsPlaceholder: View {
    let symbol: String
    let title: String
    let detail: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let action {
                Button(action: action) {
                    Text(L10n.Keys.newTerminal)
                }
                .buttonStyle(SignalButtonStyle())
                .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown until the server's terminals are read: connecting, a failure with retry, or a spinner.
struct TerminalsLoading: View {
    let server: ServerModel

    var body: some View {
        switch server.state {
        case .failed(let message):
            VStack(spacing: 14) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
                Button(L10n.Banner.retry) {
                    Task { await server.connect() }
                }
                .buttonStyle(QuietButtonStyle())
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(L10n.Terminals.connecting(server: server.config.name))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension TerminalLayout {
    var title: String {
        switch self {
        case .one: L10n.Terminals.Layouts.one
        case .cols: L10n.Terminals.Layouts.cols
        case .mainRight: L10n.Terminals.Layouts.mainRight
        case .grid: L10n.Terminals.Layouts.grid
        }
    }

    /// SF Symbol for the layout picker.
    var systemImage: String {
        switch self {
        case .one: "rectangle"
        case .cols: "rectangle.split.2x1"
        case .mainRight: "sidebar.right"
        case .grid: "square.grid.2x2"
        }
    }
}
#else
import SwiftUI

/// Terminals need the Mac app's terminal emulator; elsewhere the mode shows its placeholder.
struct TerminalsMode: View {
    var body: some View {
        ModePlaceholder(mode: .terminals)
    }
}
#endif
