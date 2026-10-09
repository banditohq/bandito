import Foundation

// Wire models for `setup.*` (docs/ARCHITECTURE.md#setup). Source: daemon/src/setup.rs. Decoded with `.convertFromSnakeCase`.

/// What a server feature needs: `screen`, `browser`, `agents` or `containers`.
public enum SetupFeature: String, ForwardCompatibleEnum, CaseIterable {
    case screen, browser, agents, containers

    public static var fallback: SetupFeature { .agents }
}

/// Whether a feature is ready on this server.
public enum SetupReady: String, ForwardCompatibleEnum {
    case ready, missing, unsupported

    public static var fallback: SetupReady { .unsupported }
}

/// How sudo can be used without a password prompt.
public enum SetupSudo: String, ForwardCompatibleEnum {
    /// `sudo -n true` works.
    case passwordless
    /// sudo is installed but asks for a password.
    case password
    /// sudo is not installed.
    case none

    public static var fallback: SetupSudo { .none }
}

/// The state of an install job (`setup.job`).
public enum SetupJobState: String, ForwardCompatibleEnum {
    case running, done, failed
    case needsPassword = "needs_password"

    public static var fallback: SetupJobState { .failed }
}

/// One thing a feature needs on the server (`setup.status`).
public struct SetupComponent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var feature: SetupFeature
    public var installed: Bool
    public var version: String?
    /// Bandito has an installer for this server.
    public var installable: Bool
    public var needsSudo: Bool
    /// What to do by hand, when it cannot be installed here.
    public var hint: String?
}

public struct SetupAgents: Codable, Sendable, Hashable {
    public var claude: SetupReady
    public var codex: SetupReady
    public var grok: SetupReady
}

public struct SetupFeatures: Codable, Sendable, Hashable {
    public var screen: SetupReady
    public var browser: SetupReady
    public var containers: SetupReady
    public var agents: SetupAgents
}

/// Wire reply of `setup.status`.
public struct SetupStatus: Codable, Sendable, Hashable {
    public var os: String
    public var arch: String
    /// `apt`, `dnf`, `pacman` or `brew`; `nil` when there is none.
    public var packageManager: String?
    public var sudo: SetupSudo
    public var components: [SetupComponent]
    public var features: SetupFeatures
}

/// Wire reply of `setup.install`.
public struct SetupInstallReply: Codable, Sendable, Hashable {
    public var jobId: String
}

/// Wire reply of `setup.job`. `log` holds the bytes from the requested offset to the end.
public struct SetupJob: Codable, Sendable, Hashable {
    public var state: SetupJobState
    public var step: String
    public var log: String
    /// The `from` to send next time.
    public var offset: UInt64
    /// The exact command the user runs in a terminal when `state` is `needsPassword`.
    public var command: String?
    public var failedComponent: String?
}
