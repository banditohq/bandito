import Foundation

// Wire model for the sign-in with a code (`integrations.device_*`, docs/ARCHITECTURE.md#integrations, feature
// `integrations_device`). The daemon asks the provider for a code and polls for the token; the app shows the code,
// opens the provider's page and reads the flow's state until it ends.

/// The answer to `integrations.device_begin`.
public struct DeviceBegun: Decodable, Sendable, Equatable {
    public var flowId: String
    /// The short code the owner types on the provider's page.
    public var userCode: String
    /// The provider's page where the code is typed.
    public var verificationUri: String
    /// Unix milliseconds the code stops working.
    public var expiresAt: Int64
    /// Seconds between the daemon's polls (the daemon polls, not the app).
    public var interval: Int

    public init(flowId: String, userCode: String, verificationUri: String, expiresAt: Int64, interval: Int = 5) {
        self.flowId = flowId
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.expiresAt = expiresAt
        self.interval = interval
    }
}

/// Why a flow failed (`reason` of `integrations.device_status`). An unknown word reads as `other`.
public enum DeviceFailure: String, Sendable, Equatable {
    /// The code ran out.
    case expired
    /// The owner refused on the provider's page.
    case denied
    /// The provider refused for another reason.
    case refused
    /// The daemon could not reach the provider for a while.
    case network
    /// The daemon could not store the sign-in.
    case store
    case other

    init(wire: String?) {
        self = wire.flatMap(DeviceFailure.init(rawValue:)) ?? .other
    }
}

/// How a flow stands (`integrations.device_status`).
public enum DeviceFlowState: Sendable, Equatable {
    case pending
    case done(integrationID: String, name: String, created: Bool)
    case failed(DeviceFailure, detail: String?)
    case cancelled
}

/// The answer to `integrations.device_status`.
public struct DeviceStatus: Decodable, Sendable, Equatable {
    public var flowId: String
    public var userCode: String?
    public var verificationUri: String?
    public var expiresAt: Int64?
    public var interval: Int?
    public var state: DeviceFlowState

    private enum CodingKeys: String, CodingKey {
        case flowId, userCode, verificationUri, expiresAt, interval, state, id, name, created, reason, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flowId = try c.decode(String.self, forKey: .flowId)
        userCode = try c.decodeIfPresent(String.self, forKey: .userCode)
        verificationUri = try c.decodeIfPresent(String.self, forKey: .verificationUri)
        expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt)
        interval = try c.decodeIfPresent(Int.self, forKey: .interval)
        switch try c.decode(String.self, forKey: .state) {
        case "done":
            state = .done(
                integrationID: try c.decode(String.self, forKey: .id),
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                created: try c.decodeIfPresent(Bool.self, forKey: .created) ?? false)
        case "failed":
            state = .failed(
                DeviceFailure(wire: try c.decodeIfPresent(String.self, forKey: .reason)),
                detail: try c.decodeIfPresent(String.self, forKey: .error))
        case "cancelled":
            state = .cancelled
        default:
            state = .pending
        }
    }

    public init(flowId: String, state: DeviceFlowState) {
        self.flowId = flowId
        self.state = state
    }
}

/// What a code sign-in is for (the same two cases as the browser sign-in's).
public enum DeviceBeginTarget: Sendable, Equatable {
    case existing(id: String)
    case draft(NewIntegration)
}

/// The server calls a code sign-in needs. `ServerModel` is the real one; tests use a fake.
@MainActor
public protocol DeviceServer: AnyObject {
    var deviceServerID: UUID { get }
    func deviceBegin(_ target: DeviceBeginTarget) async throws -> DeviceBegun
    func deviceStatus(flowId: String) async throws -> DeviceStatus
    /// Drops a flow the owner gave up. A failure is not worth telling: the daemon forgets the flow by itself.
    func deviceCancel(flowId: String) async
}

/// What to show for a code and its page: the host and the path of the address, without the scheme
/// (`github.com/login/device`), and the host alone. Nil when the address is not a web address.
public struct DevicePage: Equatable, Sendable {
    public var url: URL
    /// `github.com/login/device`
    public var address: String
    /// `github.com`
    public var host: String

    /// `text` as a page to open: https (plain http only for this Mac), so a bad answer cannot make the app open a
    /// file or another program.
    public init?(_ text: String) {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty
        else { return nil }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        self.url = url
        self.host = host
        let path = url.path == "/" ? "" : url.path
        address = host + path
    }
}

/// Seconds left until `expiresAt` (Unix ms) at `now`, never below zero.
public func deviceSecondsLeft(expiresAt: Int64, now: Date) -> Int {
    let left = Double(expiresAt) / 1000 - now.timeIntervalSince1970
    return max(0, Int(left.rounded(.up)))
}

/// `m:ss` for a countdown.
public func deviceCountdown(seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}
