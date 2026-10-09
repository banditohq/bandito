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
    private(set) var errorText: String?
    /// True while an agent holds the screen and the person tried to act on it.
    private(set) var asksToTakeControl = false
    /// Starts from the choice in Settings → Browser and screen (`screen.quality`).
    var quality: ScreenQuality = ScreenQuality(rawValue: UserDefaults.standard.string(forKey: "screen.quality") ?? "") ?? .auto {
        didSet { if quality != oldValue, connection != nil { Task { await reconnect() } } }
    }
    var clipboard: ScreenClipboard = .shared

    private var pollTask: Task<Void, Never>?

    init(server: ServerModel) {
        self.server = server
    }

    var isSupported: Bool { server.supports("screen") }

    var isAgentControlling: Bool { status?.controller == .agent }

    /// The person may act on the screen: the screen is theirs, or nobody holds it.
    var canInteract: Bool { status?.running == true && !isAgentControlling }

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

    /// Starts the screen on the server and connects to it.
    func start() async {
        do {
            status = try await server.screenStart(width: 1280, height: 800)
            errorText = nil
            await connect()
        } catch {
            errorText = BrowserModel.describe(error)
        }
    }

    /// Connects to the running screen: the VNC port goes through a one-shot tunnel, with the screen's password.
    func connect() async {
        guard let status, status.running, let vncPort = status.vncPort, let password = status.vncPassword else { return }
        disconnect()
        do {
            let local = try await server.forwardOnce(port: vncPort)
            guard let host = local.host, let port = local.port, let port16 = UInt16(exactly: port) else {
                errorText = L10n.Screen.error
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
        } catch {
            errorText = BrowserModel.describe(error)
        }
    }

    func disconnect() {
        let old = connection
        connection = nil
        vncDelegate = nil
        framebuffer = nil
        isConnected = false
        old?.disconnect()
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
        case .disconnected, .disconnecting:
            isConnected = false
        default:
            break
        }
    }

    func framebufferChanged(_ framebuffer: VNCFramebuffer) {
        self.framebuffer = framebuffer
        isConnected = true
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
