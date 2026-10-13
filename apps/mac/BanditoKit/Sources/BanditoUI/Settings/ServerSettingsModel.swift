import BanditoKit
import Observation

/// The settings of one server on its settings page: the values the daemon has now, the state of the last save, the
/// server's host numbers and the result of "copy now". The page reads the settings again when the server reports a
/// change (`settingsRevision`), so a change from another client shows here at once.
@MainActor
@Observable
final class ServerSettingsModel {
    enum SaveState: Equatable {
        case idle, saving, saved, failed
    }

    enum CopyState: Equatable {
        case idle, working, made(name: String), failed
    }

    private(set) var snapshot: ServerSettingsSnapshot?
    /// True when the settings could not be read and none is shown yet.
    private(set) var loadFailed = false
    private(set) var saveState: SaveState = .idle
    private(set) var copyState: CopyState = .idle
    private(set) var stats: HostStats?
    private(set) var statsFailed = false

    let server: ServerModel

    init(server: ServerModel, snapshot: ServerSettingsSnapshot? = nil, stats: HostStats? = nil) {
        self.server = server
        self.snapshot = snapshot
        self.stats = stats
    }

    /// Reads the settings. Call only when the server has the `server_settings` feature.
    func load() async {
        do {
            snapshot = try await server.serverSettings()
            loadFailed = false
        } catch {
            loadFailed = snapshot == nil
        }
    }

    /// Shows the change at once, sends it, and keeps the daemon's answer. A refused or failed change reads the settings
    /// again, so the page shows what the daemon really keeps.
    func apply(_ change: ServerSettingChange) async {
        guard var shown = snapshot, change.differs(from: shown.settings), let patch = change.patch else { return }
        shown.settings = change.applied(to: shown.settings)
        snapshot = shown
        saveState = .saving
        do {
            self.snapshot = try await server.updateServerSettings(patch)
            saveState = .saved
        } catch {
            saveState = .failed
            await load()
        }
    }

    /// Sends the phone access mode again so the daemon looks at its addresses now (a Tailscale that was just installed
    /// and signed in), instead of at its next round, then reads the settings.
    func recheckPhoneAccess() async {
        guard let mode = snapshot?.settings.phoneAccess, mode != .off else { return await load() }
        _ = try? await server.updateServerSettings(ServerSettingsPatch(phoneAccess: mode))
        await load()
    }

    /// Reads the host numbers of the server. Call only when the server has the `host` feature.
    func loadStats() async {
        do {
            stats = try await server.hostStats()
            statsFailed = false
        } catch {
            statsFailed = true
        }
    }

    /// Makes a database copy now (`backups.create`).
    func makeBackupNow() async {
        copyState = .working
        do {
            let backup = try await server.createBackup()
            copyState = .made(name: backup.name)
        } catch {
            copyState = .failed
        }
    }
}
