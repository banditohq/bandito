import Foundation

// The server's virtual desktop (`screen.*`, docs/ARCHITECTURE.md#screen). Linux servers only.
// The picture comes over VNC: `vncPort` and `vncPassword` go to a VNC client through `forwardOnce(port:)`.

/// Reply of `screen.start`, `screen.status` and `screen.control`.
public struct ScreenStatus: Codable, Sendable, Hashable {
    public var running: Bool
    public var display: String?
    public var width: Int?
    public var height: Int?
    /// The VNC port on the server's loopback. Nil when stopped.
    public var vncPort: Int?
    /// The VNC password (RFB uses its first 8 characters). Shown to nobody but the VNC client.
    public var vncPassword: String?
    public var startedAt: Int64?
    public var controller: ControlHolder
    /// Milliseconds since the last VNC client or agent action.
    public var idleMs: Int64?

    public init(
        running: Bool, display: String? = nil, width: Int? = nil, height: Int? = nil, vncPort: Int? = nil,
        vncPassword: String? = nil, startedAt: Int64? = nil, controller: ControlHolder = .none, idleMs: Int64? = nil
    ) {
        self.running = running
        self.display = display
        self.width = width
        self.height = height
        self.vncPort = vncPort
        self.vncPassword = vncPassword
        self.startedAt = startedAt
        self.controller = controller
        self.idleMs = idleMs
    }

    private enum CodingKeys: String, CodingKey {
        case running, display, width, height, vncPort, vncPassword, startedAt, controller, idleMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decode(Bool.self, forKey: .running)
        display = try c.decodeIfPresent(String.self, forKey: .display)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        vncPort = try c.decodeIfPresent(Int.self, forKey: .vncPort)
        vncPassword = try c.decodeIfPresent(String.self, forKey: .vncPassword)
        startedAt = try c.decodeIfPresent(Int64.self, forKey: .startedAt)
        controller = try c.decodeIfPresent(ControlHolder.self, forKey: .controller) ?? .none
        idleMs = try c.decodeIfPresent(Int64.self, forKey: .idleMs)
    }
}

extension ServerModel {
    /// Starts the screen (or returns the running one). `width` and `height` are in pixels.
    public func screenStart(workspace: String? = nil, width: Int? = nil, height: Int? = nil) async throws -> ScreenStatus {
        struct P: Encodable {
            var workspace: String?
            var width: Int?
            var height: Int?
        }
        return try await rpc().call(
            "screen.start", P(workspace: workspace, width: width, height: height), as: ScreenStatus.self)
    }

    public func screenStatus(workspace: String? = nil) async throws -> ScreenStatus {
        try await rpc().call("screen.status", WorkspaceParams(workspace: workspace), as: ScreenStatus.self)
    }

    public func screenStop(workspace: String? = nil) async throws {
        try await rpc().call("screen.stop", WorkspaceParams(workspace: workspace))
    }

    /// Who may drive the screen now: `.user` takes it from the agent, `.agent` gives it back, `.none` pauses.
    public func screenControl(_ holder: ControlHolder, workspace: String? = nil) async throws -> ScreenStatus {
        struct P: Encodable {
            var workspace: String?
            var holder: ControlHolder
        }
        return try await rpc().call(
            "screen.control", P(workspace: workspace, holder: holder), as: ScreenStatus.self)
    }
}
