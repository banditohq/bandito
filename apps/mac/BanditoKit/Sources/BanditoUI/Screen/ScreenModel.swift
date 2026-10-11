#if os(macOS)
import BanditoKit
import BanditoL10n
import Foundation
import Observation
import RoyalVNCKit
import SwiftUI

/// Picture quality of the screen. Changing it reconnects.
enum ScreenQuality: String, CaseIterable, Sendable {
    case auto, faster, sharper

    var colorDepth: VNCConnection.Settings.ColorDepth {
        switch self {
        case .auto, .sharper: .depth24Bit
        case .faster: .depth16Bit
        }
    }
}

/// Whether the clipboard is shared with the server's screen.
enum ScreenClipboard: String, CaseIterable, Sendable {
    case shared, off
}

/// The state of one server's screen: its status, and the VNC connection that shows it.
/// Lives as long as the app keeps the server (see `ScreenStore`).
@MainActor
@Observable
final class ScreenModel {
    let server: ServerModel

    private(set) var status: ScreenStatus?
    private(set) var framebuffer: VNCFramebuffer?
    private(set) var connection: VNCConnection?
    /// The delegate of `connection`; the VNC view needs it to build its framebuffer view.
    private(set) var vncDelegate: VNCSessionDelegate?
    private(set) var isConnected = false
    private(set) var errorText: UserFacingMessage?
    /// The last failure of a start or of a connection. It stays until a start is made or a picture arrives, so a poll
    /// does not wipe it. Shown by the start area with "Повторить" (see `phase`).
    private(set) var startError: UserFacingMessage?
    /// A `screen.start` call is in flight.
    private(set) var isStarting = false
    /// The connection waited `ScreenStartRules.frameTimeout` for its first picture and got none.
    private(set) var frameTimedOut = false
    private var frameTimer: Task<Void, Never>?
    /// True while an agent holds the screen and the person tried to act on it.
    private(set) var asksToTakeControl = false
    /// Starts from the choice in Settings → Browser and screen (`screen.quality`).
    var quality: ScreenQuality = ScreenQuality(rawValue: UserDefaults.standard.string(forKey: "screen.quality") ?? "") ?? .auto {
        didSet { if quality != oldValue, connection != nil { Task { await reconnect() } } }
    }
    var clipboard: ScreenClipboard = .shared

    /// The clipboard choice from Settings → Browser and screen (`screen.sharedClipboard`, on by default).
    static func storedClipboard(_ defaults: UserDefaults = .standard) -> ScreenClipboard {
        (defaults.object(forKey: "screen.sharedClipboard") as? Bool ?? true) ? .shared : .off
    }

    private var pollTask: Task<Void, Never>?

    init(server: ServerModel) {
        self.server = server
    }

    var isSupported: Bool { server.supports("screen") }

    var isAgentControlling: Bool { status?.controller == .agent }

    /// The person may act on the screen: the screen is theirs, or nobody holds it.
    var canInteract: Bool { status?.running == true && !isAgentControlling }

    /// What the screen area shows now (see `ScreenStartRules`).
    var phase: ScreenStartPhase {
        ScreenStartRules.phase(
            ScreenStartRules.Facts(
                supported: isSupported, startInFlight: isStarting, running: status?.running == true,
                hasFrame: framebuffer != nil, frameTimedOut: frameTimedOut, error: startError))
    }

    // MARK: Lifecycle

    /// Polls the status and connects while the screen is running. Called when the screen view appears.
    func attach() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Stops polling and disconnects. The screen keeps running on the server until its idle timeout.
    func detach() {
        pollTask?.cancel()
        pollTask = nil
        disconnect()
    }

    func refresh() async {
        guard isSupported else { return }
        do {
            let fresh = try await server.screenStatus()
            status = fresh
            errorText = nil
            if fresh.running {
                if connection == nil { await connect() }
            } else {
                disconnect()
            }
        } catch {
            errorText = BrowserModel.describe(error)
        }
    }

    /// Starts the screen on the server and connects to it. Shows a spinner while the call is in flight. A failure stays
    /// on the screen with "Повторить": a start that did not produce a running screen is an error too, not a silence.
    func start() async {
        guard !isStarting else { return }
        isStarting = true
        startError = nil
        defer { isStarting = false }
        do {
            let fresh = try await server.screenStart(width: 1280, height: 800)
            status = fresh
            guard fresh.running else {
                startError = UserFacingMessage(text: L10n.Screen.didNotStart, canRetry: true)
                return
            }
            await connect()
        } catch {
            startError = Self.startFailure(error)
        }
    }

    /// The sentence for a failed start or connection. Retry is always offered: starting again is the way out.
    static func startFailure(_ error: Error) -> UserFacingMessage {
        if let rpc = error as? RPCError, rpc.reason == "missing_component", let component = rpc.data?["component"]?.string {
            return UserFacingMessage(text: L10n.Screen.missingComponent(component: component), technical: rpc.message, canRetry: true)
        }
        var message = UserFacingError.message(for: error)
        message.canRetry = true
        return message
    }

    /// Connects to the running screen: the VNC port goes through a one-shot tunnel, with the screen's password.
    /// A running screen that gives no address, or a tunnel that fails, sets `startError` instead of returning quietly.
    func connect() async {
        guard let status, status.running else { return }
        guard let vncPort = status.vncPort, let password = status.vncPassword else {
            startError = UserFacingMessage(text: L10n.Screen.noAddress, canRetry: true)
            return
        }
        disconnect()
        // Settings → Browser and screen: the clipboard choice applies to each connection.
        clipboard = Self.storedClipboard()
        do {
            let local = try await server.forwardOnce(port: vncPort)
            guard let host = local.host, let port = local.port, let port16 = UInt16(exactly: port) else {
                startError = UserFacingMessage(text: L10n.Screen.error, canRetry: true)
                return
            }
            let settings = VNCConnection.Settings(
                isDebugLoggingEnabled: false,
                hostname: host,
                port: port16,
                isShared: true,
                isScalingEnabled: true,
                useDisplayLink: true,
                inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
                isClipboardRedirectionEnabled: clipboard == .shared,
                colorDepth: quality.colorDepth,
                frameEncodings: [.zrle, .tight, .zlib, .hextile, .copyRect, .raw])
            let connection = VNCConnection(settings: settings)
            let delegate = VNCSessionDelegate(model: self, password: password)
            connection.delegate = delegate
            self.connection = connection
            self.vncDelegate = delegate
            connection.connect()
            armFrameTimer()
        } catch {
            startError = Self.startFailure(error)
        }
    }

    func disconnect() {
        let old = connection
        connection = nil
        vncDelegate = nil
        framebuffer = nil
        isConnected = false
        cancelFrameTimer()
        old?.disconnect()
    }

    /// Starts the wait for the first picture. A connection that gets none in time reports `frameTimedOut`, so the
    /// area says the screen did not answer instead of waiting forever.
    private func armFrameTimer() {
        cancelFrameTimer()
        frameTimer = Task { [weak self] in
            try? await Task.sleep(for: ScreenStartRules.frameTimeout)
            guard !Task.isCancelled, let self, self.framebuffer == nil else { return }
            self.frameTimedOut = true
        }
    }

    private func cancelFrameTimer() {
        frameTimer?.cancel()
        frameTimer = nil
        if frameTimedOut { frameTimedOut = false }
    }

    private func reconnect() async {
        await connect()
    }

    // MARK: Callbacks from the VNC connection (main actor)

    func connectionStatusChanged(_ status: VNCConnection.Status) {
        switch status {
        case .connected:
            isConnected = true
            errorText = nil
            if startError != nil { startError = nil }
        case .disconnected, .disconnecting:
            isConnected = false
        default:
            break
        }
    }

    func framebufferChanged(_ framebuffer: VNCFramebuffer) {
        self.framebuffer = framebuffer
        isConnected = true
        cancelFrameTimer()
        if startError != nil { startError = nil }
    }

    // MARK: Control

    func takeControl() async {
        await setControl(.user)
    }

    func giveBack() async {
        await setControl(.agent)
    }

    func pause() async {
        await setControl(.none)
    }

    private func setControl(_ holder: ControlHolder) async {
        do {
            status = try await server.screenControl(holder)
            asksToTakeControl = false
        } catch {
            errorText = BrowserModel.describe(error)
        }
    }

    /// Called when the person clicks or types while an agent holds the screen.
    func noteAgentHasControl() {
        asksToTakeControl = true
    }

    /// Sends Ctrl+Alt+Del, when the person may act.
    func sendCtrlAltDelete() {
        guard canInteract, let connection else {
            if status?.running == true { noteAgentHasControl() }
            return
        }
        VNCKeys.sendCtrlAltDelete(connection)
    }

    /// Stops the screen on the server (it wakes again on the next start).
    func stop() async {
        disconnect()
        startError = nil
        do {
            try await server.screenStop()
            status = try await server.screenStatus()
        } catch {
            errorText = BrowserModel.describe(error)
        }
    }
}

/// One `ScreenModel` per server, so the sidebar and the main area show the same screen.
@MainActor
final class ScreenStore {
    static let shared = ScreenStore()
    private var models: [UUID: ScreenModel] = [:]

    func model(for server: ServerModel) -> ScreenModel {
        if let model = models[server.id] { return model }
        let model = ScreenModel(server: server)
        models[server.id] = model
        return model
    }
}
#endif
