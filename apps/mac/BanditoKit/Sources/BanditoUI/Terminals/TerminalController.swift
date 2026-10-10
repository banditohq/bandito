#if os(macOS)
import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// The terminals of one server as the app sees them: the workspace (what is where) and one session per
/// terminal. Kept per server in `AppModel`, so output keeps being followed while the Terminals mode is away.
@MainActor
@Observable
final class TerminalController {
    let server: ServerModel
    let workspace: TerminalWorkspace
    let font: TerminalFontStore
    private(set) var sessions: [String: TerminalSession] = [:]
    /// A place takes the terminal views: the Terminals mode, or a pane of a workbench. The last claim wins.
    func claimDisplay(_ place: String) {
        display.claim(place)
    }

    /// A place gives the terminal views back. Does nothing when another place has taken them since.
    func releaseDisplay(_ place: String) {
        display.release(place)
    }

    /// Whether the server's terminals have been read since the app started (or since the last reconnect).
    private(set) var isListed = false
    /// The last failure to show, such as a terminal that could not be opened.
    private(set) var notice: UserFacingMessage?
    /// Which place on screen draws the terminal views now (see `TerminalDisplayOwner`).
    private(set) var display = TerminalDisplayOwner()

    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var wasConnected = false
    @ObservationIgnored private var refreshing = false

    init(server: ServerModel, font: TerminalFontStore, defaults: UserDefaults = .standard) {
        self.server = server
        self.font = font
        self.workspace = TerminalWorkspace(serverID: server.id, defaults: defaults)
    }

    var focusedSession: TerminalSession? {
        workspace.focusedID.flatMap { sessions[$0] }
    }

    func session(for id: String) -> TerminalSession? {
        sessions[id]
    }

    func clearNotice() {
        notice = nil
    }

    // MARK: loading

    /// Reads the server's terminals the first time and starts watching the connection. Safe to call often.
    func start() async {
        if watchTask == nil {
            watchTask = Task { [weak self] in
                await self?.watchConnection()
            }
        }
        if !isListed {
            await refresh()
        }
    }

    /// After a reconnect, reads the list again and re-opens the streams that ended with the old connection.
    private func watchConnection() async {
        while !Task.isCancelled {
            let connected = server.state == .connected
            if connected && !wasConnected {
                await refresh()
            }
            wasConnected = connected
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Matches the workspace with the server, then attaches the sessions that are missing or ended.
    func refresh() async {
        guard server.supports("terminals"), !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let list = try await server.terminals()
            workspace.reconcile(serverTerminals: list.map { (id: $0.id, createdAt: $0.createdAt) })
            let known = workspace.knownIDs
            for id in sessions.keys where !known.contains(id) {
                sessions[id]?.stop()
                sessions[id] = nil
            }
            for info in list where known.contains(info.id) {
                if let existing = sessions[info.id] {
                    await existing.resume()
                } else {
                    await makeSession(info, attachFrom: nil)
                }
            }
            isListed = true
            notice = nil
        } catch {
            notice = UserFacingError.message(for: error)
        }
    }

    private func makeSession(_ info: TermInfo, attachFrom offset: UInt64?) async {
        let session = TerminalSession(info: info, server: server, fontSize: font.size)
        session.onTyped = { [weak self] data in self?.route(data, from: info.id) }
        session.onFocus = { [weak self] in self?.workspace.focus(info.id) }
        session.onPinch = { [weak self] delta in
            guard let self else { return }
            self.font.set(TerminalFontSize.scaled(self.font.size, by: delta))
        }
        session.onClosed = { [weak self] in self?.forget(info.id) }
        sessions[info.id] = session
        await session.attach(from: offset)
    }

    // MARK: opening, closing

    /// Starts a terminal on the server and puts it on screen (or in the dock when the grid is full).
    /// `afterFocused` places it next to the focused pane (split).
    /// Opens a terminal on the server. Returns its id, or `nil` when it could not be opened (then `notice` says why).
    @discardableResult
    func openNew(cwd: String?, afterFocused: Bool) async -> String? {
        let size = focusedSize()
        do {
            let info = try await server.openTerminal(cwd: cwd, cols: size.cols, rows: size.rows)
            let placement = workspace.add(info.id, afterFocused: afterFocused, at: .now)
            await makeSession(info, attachFrom: nil)
            // A new terminal takes the keyboard at once, so typing starts without a click. One in the dock has no pane yet.
            if placement == .screen {
                focusKeyboard(on: info.id)
            }
            return info.id
        } catch {
            notice = UserFacingError.message(for: error).wrapped { L10n.Terminals.newFailed(message: $0) }
            return nil
        }
    }

    /// Moves keyboard focus to the pane of `id`: now when it is in a window, else as soon as it is put in one.
    func focusKeyboard(on id: String) {
        guard let view = session(for: id)?.view else { return }
        if let window = view.window {
            window.makeFirstResponder(view)
        } else {
            view.wantsFocus = true
        }
    }

    /// Ends a terminal on the server and forgets it. The server error, if any, is shown; the terminal is
    /// forgotten anyway, and a terminal that is still running comes back from the dock on the next refresh.
    func close(_ id: String) async {
        do {
            try await server.closeTerminal(id)
        } catch {
            notice = UserFacingError.message(for: error)
        }
        forget(id)
    }

    /// Removes a terminal from the app. It does not tell the server.
    private func forget(_ id: String) {
        sessions[id]?.stop()
        sessions[id] = nil
        workspace.close(id)
    }

    /// Starts the same command again in the same folder, in the place of an exited terminal.
    func restart(_ id: String) async {
        guard let old = sessions[id]?.info else { return }
        do {
            let info = try await server.openTerminal(
                cwd: old.cwd, command: old.command, title: old.title, cols: old.cols, rows: old.rows)
            try? await server.closeTerminal(id)
            sessions[id]?.stop()
            sessions[id] = nil
            workspace.replace(id, with: info.id)
            await makeSession(info, attachFrom: nil)
        } catch {
            notice = UserFacingError.message(for: error).wrapped { L10n.Terminals.newFailed(message: $0) }
        }
    }

    func rename(_ id: String, to title: String) async {
        await sessions[id]?.rename(to: title)
    }

    // MARK: layout and dock

    func collapse(_ id: String) {
        guard let session = sessions[id] else { return }
        workspace.collapse(id, at: .now, lines: session.activity.lines)
    }

    @discardableResult
    func restore(_ id: String) -> Bool {
        if workspace.restore(id) { return true }
        notice = UserFacingMessage(text: L10n.Terminals.noRoom)
        return false
    }

    func restoreLast() {
        if workspace.collapsed.isEmpty { return }
        if workspace.restoreLast() == nil {
            notice = UserFacingMessage(text: L10n.Terminals.noRoom)
        }
    }

    func setLayout(_ layout: TerminalLayout) {
        workspace.setLayout(layout, at: .now)
    }

    /// Stops following every terminal (the server was removed). The terminals keep running on the server.
    func detachAll() async {
        watchTask?.cancel()
        watchTask = nil
        let all = Array(sessions.values)
        sessions = [:]
        for session in all {
            await session.detach()
        }
    }

    // MARK: input

    /// Sends typed bytes to the terminal they were typed in, and to every pane on screen when "input to all" is on.
    func route(_ data: Data, from id: String) {
        let targets = workspace.inputToAll ? workspace.onScreen : [id]
        for target in targets {
            sessions[target]?.enqueueInput(data)
        }
    }

    // MARK: helpers

    /// Size for a new terminal: the focused pane's emulator size, or a default.
    private func focusedSize() -> (cols: Int, rows: Int) {
        if let session = focusedSession {
            let terminal = session.view.getTerminal()
            if (1...1000).contains(terminal.cols), (1...1000).contains(terminal.rows) {
                return (terminal.cols, terminal.rows)
            }
        }
        return (100, 30)
    }
}
#endif
