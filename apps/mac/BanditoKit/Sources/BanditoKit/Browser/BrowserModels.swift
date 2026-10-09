import Foundation

// Wire models of `browser.*` and of the browser's DevTools HTTP list. Decoded with `RPCClient.decoder`
// (snake_case on the wire). The screen feature reuses `ControlHolder`.

/// Who may drive a shared browser or screen right now.
public enum ControlHolder: String, Codable, Sendable, Hashable {
    /// The person at the app.
    case user
    /// An agent (Forge, Scout…).
    case agent
    /// Nobody holds it: the agent may act, the person may take over.
    case none
}

/// Reply of `browser.start`, `browser.status` and `browser.control`.
public struct BrowserStatus: Codable, Sendable, Hashable {
    public var running: Bool
    /// The browser's DevTools port on the server's loopback. Nil when stopped.
    public var cdpPort: Int?
    /// Path of the browser-level DevTools WebSocket, for `Target.*` calls.
    public var browserWsPath: String?
    public var pid: Int?
    public var startedAt: Int64?
    public var controller: ControlHolder

    public init(
        running: Bool, cdpPort: Int? = nil, browserWsPath: String? = nil, pid: Int? = nil,
        startedAt: Int64? = nil, controller: ControlHolder = .none
    ) {
        self.running = running
        self.cdpPort = cdpPort
        self.browserWsPath = browserWsPath
        self.pid = pid
        self.startedAt = startedAt
        self.controller = controller
    }

    private enum CodingKeys: String, CodingKey {
        case running, cdpPort, browserWsPath, pid, startedAt, controller
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decode(Bool.self, forKey: .running)
        cdpPort = try c.decodeIfPresent(Int.self, forKey: .cdpPort)
        browserWsPath = try c.decodeIfPresent(String.self, forKey: .browserWsPath)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        startedAt = try c.decodeIfPresent(Int64.self, forKey: .startedAt)
        controller = try c.decodeIfPresent(ControlHolder.self, forKey: .controller) ?? .none
    }
}

/// One entry of the browser's `/json/list`: a tab (`type == "page"`) or another target such as a worker.
public struct BrowserTab: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String
    public var title: String
    public var url: String

    public var isPage: Bool { type == "page" }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, url
    }
}
