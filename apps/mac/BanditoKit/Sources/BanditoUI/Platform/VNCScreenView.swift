#if os(macOS)
import AppKit
import RoyalVNCKit
import SwiftUI

// The server's screen as a VNC framebuffer (RoyalVNCKit). The connection itself is owned by `ScreenModel`;
// this file is the AppKit side: the view that shows the framebuffer, and the delegate that receives its events.

/// Receives RoyalVNCKit's callbacks (on its own queue) and passes them to the main actor.
/// Holds the password only for the RFB handshake.
final class VNCSessionDelegate: NSObject, VNCConnectionDelegate, @unchecked Sendable {
    private weak var model: ScreenModel?
    private let password: String

    init(model: ScreenModel, password: String) {
        self.model = model
        self.password = password
    }

    func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        let status = connectionState.status
        Task { @MainActor in self.model?.connectionStatusChanged(status) }
    }

    func connection(
        _ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (_ credential: VNCCredential?) -> Void
    ) {
        completion(VNCPasswordCredential(password: password))
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        let box = FramebufferBox(framebuffer)
        Task { @MainActor in self.model?.framebufferChanged(box.value) }
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        let box = FramebufferBox(framebuffer)
        Task { @MainActor in self.model?.framebufferChanged(box.value) }
    }

    func connection(
        _ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
        x: UInt16, y: UInt16, width: UInt16, height: UInt16
    ) {}

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
}

/// Carries a framebuffer from RoyalVNCKit's queue to the main actor. Only read there.
private final class FramebufferBox: @unchecked Sendable {
    let value: VNCFramebuffer

    init(_ value: VNCFramebuffer) {
        self.value = value
    }
}

/// Shows the framebuffer of `model`'s connection. Built once the framebuffer exists, and rebuilt on a new connection.
struct VNCScreenView: NSViewRepresentable {
    let model: ScreenModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let connection = model.connection, let framebuffer = model.framebuffer, let delegate = model.vncDelegate else {
            container.subviews.forEach { $0.removeFromSuperview() }
            context.coordinator.shown = nil
            return
        }
        let id = ObjectIdentifier(framebuffer)
        guard context.coordinator.shown != id else { return }
        context.coordinator.shown = id
        container.subviews.forEach { $0.removeFromSuperview() }
        let view = VNCCAFramebufferView(
            frame: container.bounds, framebuffer: framebuffer, connection: connection, connectionDelegate: delegate)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// The framebuffer the current view shows.
        var shown: ObjectIdentifier?
    }
}

/// Sends Ctrl+Alt+Del through the VNC connection (the keys go down, then up in reverse).
@MainActor
enum VNCKeys {
    static func sendCtrlAltDelete(_ connection: VNCConnection) {
        connection.keyDown(.control)
        connection.keyDown(.option)
        connection.keyDown(.forwardDelete)
        connection.keyUp(.forwardDelete)
        connection.keyUp(.option)
        connection.keyUp(.control)
    }
}

/// Toggles full screen for the key window.
@MainActor
enum WindowFullScreen {
    static func toggle() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}

/// Opens an external web address in the Mac's default browser.
@MainActor
enum ExternalLinks {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
#endif
