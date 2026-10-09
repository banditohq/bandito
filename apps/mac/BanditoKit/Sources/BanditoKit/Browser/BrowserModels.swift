import Foundation

// Wire models of `browser.*` and of `GET /v1/browser/tabs`. Decoded with `RPCClient.decoder`
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
    /// How the app reaches the browser's DevTools protocol: `"relay"` while it runs (see
    /// docs/ARCHITECTURE.md#browser), nil when stopped.
    public var cdp: String?
    public var pid: Int?
    public var startedAt: Int64?
    public var controller: ControlHolder

    /// The browser is up and its DevTools routes (`/v1/browser/cdp…`) can be used.
    public var isRelay: Bool { running && cdp == "relay" }

    /// What the app shows when it gives up on the browser: not running, nothing to connect to.
    public static let stopped = BrowserStatus(running: false)

    public init(
        running: Bool, cdp: String? = nil, pid: Int? = nil, startedAt: Int64? = nil,
        controller: ControlHolder = .none
    ) {
        self.running = running
        self.cdp = cdp
        self.pid = pid
        self.startedAt = startedAt
        self.controller = controller
    }

    private enum CodingKeys: String, CodingKey {
        case running, cdp, pid, startedAt, controller
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decode(Bool.self, forKey: .running)
        cdp = try c.decodeIfPresent(String.self, forKey: .cdp)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        startedAt = try c.decodeIfPresent(Int64.self, forKey: .startedAt)
        controller = try c.decodeIfPresent(ControlHolder.self, forKey: .controller) ?? .none
    }
}

/// One entry of `GET /v1/browser/tabs`: a page (`type == "page"`); the daemon lists only pages.
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
