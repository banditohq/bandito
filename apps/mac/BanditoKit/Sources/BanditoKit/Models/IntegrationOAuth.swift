import Foundation

// Wire model for the browser sign-in of an integration (`integrations.oauth_*`, docs/ARCHITECTURE.md#integrations).
// The daemon does the sign-in; the app opens the address it returns and hands back the code the browser brings.

/// What a sign-in is for.
public enum OAuthBeginTarget: Sendable, Equatable {
    /// An integration that exists already (signing in again).
    case existing(id: String)
    /// A service from the catalog: the daemon makes the integration when the sign-in succeeds.
    case draft(NewIntegration)
}

/// The answer to `integrations.oauth_begin`.
public struct OAuthBegun: Decodable, Sendable, Equatable {
    /// The service's page where the owner allows access. Open it in the browser.
    public var authorizeUrl: String
    /// Comes back in the callback; the daemon knows which sign-in it belongs to.
    public var state: String
    /// Unix milliseconds the daemon stops waiting.
    public var expiresAt: Int64?

    public init(authorizeUrl: String, state: String, expiresAt: Int64? = nil) {
        self.authorizeUrl = authorizeUrl
        self.state = state
        self.expiresAt = expiresAt
    }
}

/// The answer to `integrations.oauth_complete`.
public struct OAuthCompleted: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// The sign-in made the integration.
    public var created: Bool
    public var status: String
    public var expiresAt: Int64?

    public init(id: String, name: String, created: Bool, status: String = "connected", expiresAt: Int64? = nil) {
        self.id = id
        self.name = name
        self.created = created
        self.status = status
        self.expiresAt = expiresAt
    }
}

/// How the sign-in of one integration stands (`integrations.oauth_status`).
public enum OAuthConnection: Sendable, Equatable {
    case connected
    /// The service refused the renewal (or the token ran out with nothing to renew it): the owner signs in again.
    case needsLogin
    /// The sign-in is there, but renewing it keeps failing for a reason that may pass (the service is down): the
    /// daemon tries again by itself.
    case refreshError
    case notConnected

    init(wire: String) {
        switch wire {
        case "connected": self = .connected
        case "refresh_error": self = .refreshError
        case "needs_login": self = .needsLogin
        default: self = .notConnected
        }
    }
}

public struct OAuthStatus: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var status: String
    public var expiresAt: Int64?
    public var scope: String?
    /// For `refresh_error`: a short text from the daemon (English), fit for a tooltip.
    public var error: String?

    public var connection: OAuthConnection { OAuthConnection(wire: status) }

    public init(
        id: String, name: String, status: String, expiresAt: Int64? = nil, scope: String? = nil, error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.expiresAt = expiresAt
        self.scope = scope
        self.error = error
    }
}

/// What the browser brings back to `bandito://oauth/callback`.
public struct OAuthCallback: Equatable, Sendable {
    public static let scheme = "bandito"
    public var state: String?
    public var code: String?
    /// The issuer, when the service sent it (RFC 9207). The daemon checks it.
    public var iss: String?
    /// The service's `error`, for example `access_denied`.
    public var error: String?

    public init(state: String? = nil, code: String? = nil, iss: String? = nil, error: String? = nil) {
        self.state = state
        self.code = code
        self.iss = iss
        self.error = error
    }

    /// The callback in `url`, or nil when the address is not `bandito://oauth/callback`. Values that are too long
    /// to be real are dropped.
    public static func parse(_ url: URL) -> OAuthCallback? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "oauth", url.path == "/callback",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String, max: Int) -> String? {
            guard let text = items.first(where: { $0.name == name })?.value, !text.isEmpty, text.count <= max
            else { return nil }
            return text
        }
        return OAuthCallback(
            state: value("state", max: 512), code: value("code", max: 4096), iss: value("iss", max: 2048),
            error: value("error", max: 64))
    }
}

/// The server calls a sign-in needs. `ServerModel` is the real one; tests use a fake.
@MainActor
public protocol OAuthServer: AnyObject {
    var oauthServerID: UUID { get }
    func oauthBegin(_ target: OAuthBeginTarget) async throws -> OAuthBegun
    func oauthComplete(state: String, code: String, iss: String?) async throws -> OAuthCompleted
    /// Drops a sign-in the owner gave up. A failure is not worth telling: the daemon forgets it in ten minutes.
    func oauthCancel(state: String) async
}
