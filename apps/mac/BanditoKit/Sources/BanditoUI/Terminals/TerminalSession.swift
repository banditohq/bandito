#if os(macOS)
import AppKit
import BanditoKit
import BanditoL10n
import Foundation
import Observation
@preconcurrency import SwiftTerm

/// One terminal the app follows: its output stream, its emulator view and what the output has been doing.
///
/// The session lives as long as the terminal is in the workspace, on screen or collapsed. Output keeps
/// flowing into the emulator and the activity counters while the pane is collapsed (docs/APP_SPEC.md,
/// Keys and gestures: "Collapse (keeps running)").
@MainActor
@Observable
final class TerminalSession {
    struct Exit: Equatable {
        var code: Int?
        var signal: Int?
    }

    let id: String
    private(set) var info: TermInfo
    private(set) var activity = TerminalActivity()
    private(set) var exit: Exit?
    /// Set when following the terminal failed. Cleared by the next successful attach.
    private(set) var errorMessage: UserFacingMessage?
    /// True while the output stream is open.
    private(set) var isAttached = false

    @ObservationIgnored let view: BanditoTerminalView
    @ObservationIgnored private let bridge = TerminalViewBridge()
    @ObservationIgnored private let server: ServerModel
    @ObservationIgnored private var stream: TerminalStream?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var batcher = TerminalInputBatcher()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Input is sent one call after another, so the daemon sees the keystrokes in order.
    @ObservationIgnored private var sendQueue: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var lastSize: (cols: Int, rows: Int)

    /// Keyboard bytes the user typed in this terminal. The controller decides where they go.
    @ObservationIgnored var onTyped: ((Data) -> Void)?
    @ObservationIgnored var onFocus: (() -> Void)?
    @ObservationIgnored var onPinch: ((Double) -> Void)?
    /// The terminal reported `closed` (it was closed on the server).
    @ObservationIgnored var onClosed: (() -> Void)?
    /// Output bytes as they are drawn. The login step looks for the link in them.
    @ObservationIgnored var onOutput: ((Data) -> Void)?

    init(info: TermInfo, server: ServerModel, fontSize: Double) {
        self.id = info.id
        self.info = info
        self.server = server
        self.lastSize = (info.cols, info.rows)
        view = BanditoTerminalView(frame: .zero, font: TerminalTheme.font(size: fontSize))
        view.terminalDelegate = bridge
        view.installColors(TerminalTheme.ansi)
        view.nativeBackgroundColor = TerminalTheme.background
        view.nativeForegroundColor = TerminalTheme.foreground
        view.caretColor = TerminalTheme.caret
        // Links in the output are underlined on hover and opened with a click (see the bridge: https only).
        view.linkHighlightMode = .hoverWithModifier
        // The emulator must match the daemon's size before the first output arrives.
        view.resize(cols: info.cols, rows: info.rows)

        bridge.onInput = { [weak self] data in self?.onTyped?(data) }
        bridge.onSize = { [weak self] cols, rows in self?.scheduleResize(cols: cols, rows: rows) }
        view.onFocus = { [weak self] in self?.onFocus?() }
        view.onPinch = { [weak self] delta in self?.onPinch?(delta) }
    }

    // MARK: attaching

    /// Opens the output stream. `offset` continues from where a previous stream stopped; `nil` starts with the
    /// snapshot the daemon keeps.
    func attach(from offset: UInt64? = nil) async {
        guard !isAttached else { return }
        do {
            let next = try await server.attach(id, from: offset)
            stream = next
            isAttached = true
            errorMessage = nil
            pump = Task { [weak self] in
                for await chunk in next.chunks {
                    self?.handle(chunk)
                }
                // Only the current stream may mark the session detached: an older one can end late.
                if self?.stream === next {
                    self?.isAttached = false
                }
            }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    /// Re-opens the stream after a connection drop, from the last byte this session has.
    func resume() async {
        guard !isAttached else { return }
        await attach(from: stream?.nextOffset)
    }

    /// Stops following the terminal and tells the daemon, which keeps the process running.
    func detach() async {
        stop()
        try? await server.detach(id)
    }

    /// Stops the local pump and timers. The daemon-side stream is ended by `detach()` or by the terminal closing.
    func stop() {
        pump?.cancel()
        pump = nil
        flushTask?.cancel()
        resizeTask?.cancel()
        isAttached = false
    }

    // MARK: output

    private func handle(_ chunk: TerminalChunk) {
        switch chunk {
        case .output(let data):
            activity.record(data, at: .now)
            let bytes = [UInt8](data)
            view.feed(byteArray: bytes[...])
            onOutput?(data)
        case .gap(let lost):
            printLine(L10n.Terminals.gap(kb: String(max(1, Int(lost / 1024)))))
        case .exit(let code, let signal):
            let status = Exit(code: code, signal: signal)
            exit = status
            info.state = .exited(code: code, signal: signal)
            printLine(Self.exitDescription(status))
        case .closed:
            isAttached = false
            onClosed?()
        case .error(let kind):
            errorMessage = UserFacingError.message(for: kind).wrapped { L10n.Terminals.error(message: $0) }
        }
    }

    /// A line in the terminal, dimmed, on its own row.
    private func printLine(_ text: String) {
        view.feed(text: "\u{1B}[2m\(text)\u{1B}[0m\r\n")
    }

    /// Clears the visible screen and the scrollback of this emulator. The program and its output are untouched.
    func clearScreen() {
        view.feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J")
    }

    static func exitDescription(_ exit: Exit) -> String {
        if let code = exit.code { return L10n.Terminals.Exit.code(code: String(code)) }
        if let signal = exit.signal { return L10n.Terminals.Exit.signal(signal: String(signal)) }
        return L10n.Terminals.Exit.plain
    }

    // MARK: input

    /// Queues keyboard bytes. They go out in batches of up to 4 KiB, at most 16 ms after the first byte.
    func enqueueInput(_ data: Data) {
        let ready = batcher.add(data, now: ProcessInfo.processInfo.systemUptime)
        for chunk in ready {
            send(chunk)
        }
        guard flushTask == nil, let deadline = batcher.deadline else { return }
        let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            if let rest = self.batcher.flush() {
                self.send(rest)
            }
        }
    }

    private func send(_ data: Data) {
        let previous = sendQueue
        let id = id
        let server = server
        sendQueue = Task {
            await previous?.value
            // A refused write (the terminal exited, the connection dropped) is not retried: the output says what happened.
            try? await server.input(data, to: id)
        }
    }

    // MARK: size

    /// Sends the new size once it has settled for 150 ms.
    private func scheduleResize(cols: Int, rows: Int) {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            guard cols != self.lastSize.cols || rows != self.lastSize.rows else { return }
            self.lastSize = (cols, rows)
            if let updated = try? await self.server.resize(self.id, cols: cols, rows: rows) {
                self.info = updated
            }
        }
    }

    // MARK: commands

    func rename(to title: String) async {
        if let updated = try? await server.rename(id, title: title) {
            info = updated
        }
    }
}
#endif
