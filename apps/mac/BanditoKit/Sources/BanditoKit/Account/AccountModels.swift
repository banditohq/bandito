import Foundation

/// A signed-in session. The token is a secret: `AccountClient` keeps this whole value in the Keychain only.
public struct Session: Codable, Sendable, Equatable {
    public var token: String
    public var user: AccountUser
    public var device: DeviceRef

    public init(token: String, user: AccountUser, device: DeviceRef) {
        self.token = token
        self.user = user
        self.device = device
    }
}

public struct AccountUser: Codable, Sendable, Equatable {
    public var id: String
    public var email: String?
    public var name: String?
    public var githubLogin: String?

    public init(id: String, email: String?, name: String?, githubLogin: String?) {
        self.id = id
        self.email = email
        self.name = name
        self.githubLogin = githubLogin
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, name
        case githubLogin = "github_login"
    }
}

/// This device as the account knows it.
public struct DeviceRef: Codable, Sendable, Equatable {
    public var id: String
    /// False while another approved device has not let this one in yet.
    public var approved: Bool

    public init(id: String, approved: Bool) {
        self.id = id
        self.approved = approved
    }
}

/// A device of the account, as `GET /me` lists it.
public struct AccountDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var approved: Bool
    public var createdAt: String
    public var lastSeenAt: String
    /// True for the device that made the request.
    public var current: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, platform, approved, current
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

/// A device waiting for approval, as `GET /devices/pending` lists it.
public struct PendingDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    /// The new device's X25519 public key (base64): the envelope is sealed to it.
    public var publicKey: String
    public var createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id, name, platform
        case publicKey = "public_key"
        case createdAt = "created_at"
    }
}

/// `GET /me`: the signed-in user, this device, and every device of the account.
public struct Me: Codable, Sendable, Equatable {
    public var user: AccountUser
    public var device: DeviceRef
    public var devices: [AccountDevice]
}

/// The sync-key envelope a pending device receives after approval.
public struct Envelope: Codable, Sendable, Equatable {
    public var envelope: String
    /// The X25519 public key of the device that approved (base64). Informational: the envelope is not signed.
    public var fromPublicKey: String

    public init(envelope: String, fromPublicKey: String) {
        self.envelope = envelope
        self.fromPublicKey = fromPublicKey
    }

    private enum CodingKeys: String, CodingKey {
        case envelope
        case fromPublicKey = "from_public_key"
    }
}

/// The encrypted sync blob and its version. `blob` is base64 ciphertext.
public struct SyncBlob: Sendable, Equatable {
    public var version: Int
    public var blob: String

    public init(version: Int, blob: String) {
        self.version = version
        self.blob = blob
    }
}

/// A GitHub device-flow sign-in started on the server. The app shows `userCode` and opens `verificationURI`.
public struct GitHubFlow: Sendable, Equatable {
    public var flowID: String
    public var userCode: String
    public var verificationURI: URL
    /// Seconds to wait between polls.
    public var interval: Int
    /// Seconds until the code expires.
    public var expiresIn: Int

    public init(flowID: String, userCode: String, verificationURI: URL, interval: Int, expiresIn: Int) {
        self.flowID = flowID
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

/// One answer to a GitHub poll.
public enum PollResult: Sendable, Equatable {
    /// The user has not confirmed yet: wait and poll again.
    case pending
    /// Poll no faster than this many seconds from now.
    case slowDown(interval: Int)
    /// Signed in. The session is already stored.
    case signedIn(Session)
    /// The code expired, or the flow is unknown: start again.
    case expired
    /// The user refused on GitHub.
    case denied
}

/// The device this app reports at sign-in. The name is shown to the user on the other devices.
public struct DeviceDescriptor: Sendable, Equatable {
    public var name: String
    /// `macos` or `ios`.
    public var platform: String

    public init(name: String, platform: String) {
        self.name = name
        self.platform = platform
    }

    /// This machine. On macOS the name is the Mac's name; elsewhere pass an explicit name if the
    /// host hostname is not what the user expects.
    public static var current: DeviceDescriptor {
        #if os(macOS)
        let platform = "macos"
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        let platform = "ios"
        let name = ProcessInfo.processInfo.hostName
        #endif
        return DeviceDescriptor(name: String(name.prefix(100)), platform: platform)
    }
}
