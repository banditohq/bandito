import Foundation

// The server settings the owner changes from the app (docs/ARCHITECTURE.md#server-settings). Feature
// `server_settings` in `daemon.info`. An older daemon has none of this: check `server.supports("server_settings")`.

/// `auto_update`: what the daemon does about a newer release.
public enum AutoUpdateMode: String, ForwardCompatibleEnum, CaseIterable {
    /// No check runs by itself.
    case off
    /// The daily check runs and a newer release is written to the log (the daemon's default).
    case notify
    /// As `notify`, and a newer release is installed at night when no agent works.
    case install

    /// A value this app does not know: the daemon's default, which only logs a newer release.
    public static var fallback: AutoUpdateMode { .notify }
}

/// One set of the server's settings: what applies now (`settings`) or the daemon's defaults (`defaults`).
public struct ServerSettingValues: Codable, Sendable, Hashable {
    /// A screen with no viewer and no agent call for this many minutes stops (5 to 240).
    public var screenIdleMinutes: Int
    /// How many agents run a turn at once. 0 means no limit.
    public var maxRunningAgents: Int
    /// How often a database copy is due, in hours (6, 12, 24, 48 or 168).
    public var backupEveryHours: Int
    /// How many database copies are kept (3 to 60).
    public var backupKeep: Int
    public var autoUpdate: AutoUpdateMode
    /// The release channel. Only `stable` exists today.
    public var updateChannel: String
    /// The approval mode a new agent gets when its creation does not set one.
    public var defaultApprovalMode: ApprovalMode
}

/// The reply of `server.settings_get` and `server.settings_set`.
public struct ServerSettingsSnapshot: Codable, Sendable, Hashable {
    public var settings: ServerSettingValues
    public var defaults: ServerSettingValues
}

/// A partial change for `server.settings_set`. A field left nil is not sent, so the daemon keeps its value.
public struct ServerSettingsPatch: Encodable, Sendable, Hashable {
    public var screenIdleMinutes: Int?
    public var maxRunningAgents: Int?
    public var backupEveryHours: Int?
    public var backupKeep: Int?
    public var autoUpdate: AutoUpdateMode?
    public var defaultApprovalMode: ApprovalMode?

    /// The encoder turns these camelCase names into the daemon's snake_case names (`screen_idle_minutes`).
    public init(
        screenIdleMinutes: Int? = nil, maxRunningAgents: Int? = nil, backupEveryHours: Int? = nil,
        backupKeep: Int? = nil, autoUpdate: AutoUpdateMode? = nil, defaultApprovalMode: ApprovalMode? = nil
    ) {
        self.screenIdleMinutes = screenIdleMinutes
        self.maxRunningAgents = maxRunningAgents
        self.backupEveryHours = backupEveryHours
        self.backupKeep = backupKeep
        self.autoUpdate = autoUpdate
        self.defaultApprovalMode = defaultApprovalMode
    }

    /// True when no field is set (nothing to send).
    public var isEmpty: Bool {
        screenIdleMinutes == nil && maxRunningAgents == nil && backupEveryHours == nil && backupKeep == nil
            && autoUpdate == nil && defaultApprovalMode == nil
    }
}

extension ServerModel {
    /// The settings as they apply now, and the daemon's defaults.
    public func serverSettings() async throws -> ServerSettingsSnapshot {
        try await rpc().call("server.settings_get", NoParams(), as: ServerSettingsSnapshot.self)
    }

    /// Changes the settings in `patch`. The daemon checks every value first and writes nothing when one is refused
    /// (the error is `INVALID_PARAMS`). Returns the settings after the change.
    public func updateServerSettings(_ patch: ServerSettingsPatch) async throws -> ServerSettingsSnapshot {
        try await rpc().call("server.settings_set", patch, as: ServerSettingsSnapshot.self)
    }
}
