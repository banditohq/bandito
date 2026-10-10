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
            NoServerView(symbol: "terminal")
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
        let place = TerminalDisplayOwner.terminals
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
        // The Terminals mode draws the terminal views while it is on screen; a workbench pane gives them up.
        .onAppear { controller.claimDisplay(place) }
        .onDisappear { controller.releaseDisplay(place) }
        .onChange(of: router.terminalRequest) { _, request in
            guard let request else { return }
            router.terminalRequest = nil
            perform(request.action, controller: controller)
        }
        // "Open terminal here" waits for the list, then opens a terminal in the folder. It must not wait for a
        // click: the mode is often entered for this alone, and an empty pane would look like nothing happened.
        .onChange(of: controller.isListed, initial: true) { _, _ in
            openPendingFolder(controller)
        }
        .onChange(of: router.pendingTerminalCwd) { _, _ in
            openPendingFolder(controller)
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

    /// Takes the folder waiting in the Router (once) and opens a new terminal there, as soon as the server lists
    /// its terminals.
    private func openPendingFolder(_ controller: TerminalController) {
        guard controller.isListed, server.supports("terminals"), let cwd = router.takeTerminalCwd() else { return }
        Task { await controller.openNew(cwd: cwd, afterFocused: false) }
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
                TerminalNoticeStrip(message: notice) { controller.clearNotice() }
            }
            if controller.workspace.inputToAll {
                TerminalInputToAllStrip { controller.workspace.inputToAll = false }
            }
            TerminalGrid(controller: controller, requestClose: requestClose)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The dock is there only while some terminal is collapsed.
            if !controller.workspace.collapsed.isEmpty {
                TerminalDock(controller: controller)
            }
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

/// 52 pt: the desktop name and the count on the left. On the right, quiet 28 pt icons, as in the file viewer's bar:
/// the layout menu, "new terminal", and "…" with "input to all".
struct TerminalToolbar: View {
    let controller: TerminalController
    let onNew: () -> Void
    @Environment(Keymap.self) private var keymap

    var body: some View {
        let workspace = controller.workspace
        HStack(spacing: 10) {
            Text(L10n.Mode.terminals)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .fixedSize()
            Text(L10n.Terminals.windowCount(count: workspace.onScreen.count))
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 12)
            layoutMenu
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .banditoButton(.icon(size: 28, label: L10n.Keys.newTerminal))
            .help(newTerminalHelp)
            ViewerMoreMenu {
                Toggle(L10n.Terminals.inputToAll, isOn: Bindable(workspace).inputToAll)
                    .help(L10n.Terminals.inputToAllHint)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .titleBarZoomOnDoubleClick()
        .background(Color(hex: 0x12100E))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
    }

    private var newTerminalHelp: String {
        guard let symbols = keymap.binding(for: "terminals.new")?.symbols else { return L10n.Keys.newTerminal }
        return "\(L10n.Keys.newTerminal) \(symbols)"
    }

    /// One icon for the layout on screen. The menu lists all four; the current one carries a check.
    private var layoutMenu: some View {
        let current = controller.workspace.layout
        return Menu {
            ForEach(TerminalLayout.allCases, id: \.self) { layout in
                Button(layout.title, systemImage: layout == current ? "checkmark" : layout.systemImage) {
                    controller.setLayout(layout)
                }
            }
        } label: {
            Image(systemName: current.systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .banditoButton(.icon(size: 28, label: L10n.Terminals.layoutTitle))
        .help(L10n.Terminals.layoutTitle)
        .fixedSize()
    }
}

/// A one-line message above the grid. Tapping the cross dismisses it.
struct TerminalNoticeStrip: View {
    let message: UserFacingMessage
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            UserFacingErrorView(message: message)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
            .foregroundStyle(Color.Bandito.text3)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 30)
        .background(Color.Bandito.signal.opacity(0.08))
    }
}

/// Above the grid while "input to all" is on: what is typed goes to every pane. One click turns it off.
struct TerminalInputToAllStrip: View {
    let turnOff: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BanditoPalette.peach)
            Text(L10n.Terminals.inputToAll)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text)
            Spacer(minLength: 8)
            Button(action: turnOff) {
                Text(L10n.Terminals.inputToAllOff)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
            }
            .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
            .foregroundStyle(BanditoPalette.peach)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 30)
        .background(Color.Bandito.signal.opacity(0.12))
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
                .banditoButton(.signal())
                .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown until the server's terminals are read: connecting, a failure with retry, or a spinner. A connection that does
/// not come within `connectTimeout` gives way to an error with a retry, instead of a spinner that never ends.
struct TerminalsLoading: View {
    let server: ServerModel
    /// Counts the attempts; a retry starts a new one, with its own timer.
    @State private var attempt = 0
    @State private var timedOut = false

    /// How long the connection may take before the page says so.
    static let connectTimeout: Duration = .seconds(10)

    var body: some View {
        Group {
            switch server.state {
            case .failed(let kind):
                VStack(spacing: 14) {
                    UserFacingErrorView(message: UserFacingError.message(for: kind))
                        .frame(maxWidth: 420)
                    Button(L10n.Banner.retry, action: reconnect)
                        .banditoButton(.quiet())
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if timedOut, server.state != .connected {
                    VStack(spacing: 14) {
                        UserFacingErrorView(
                            message: UserFacingMessage(
                                text: L10n.Terminals.connectTimeout(server: server.config.name), canRetry: true),
                            onRetry: retry)
                            .frame(maxWidth: 420)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
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
        .task(id: attempt) {
            timedOut = false
            do {
                try await Task.sleep(for: Self.connectTimeout)
            } catch {
                return
            }
            timedOut = true
        }
    }

    /// A new attempt from a clean state: a stalled attempt is dropped first, since `connect` does nothing while one runs.
    private func retry() {
        attempt += 1
        reconnect()
    }

    private func reconnect() {
        Task {
            await server.disconnect()
            await server.connect()
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
