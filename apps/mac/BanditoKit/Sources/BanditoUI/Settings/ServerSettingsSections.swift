import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings of one server → Agents by default: the folder the server's agents are kept in (this Mac's own choice, per
/// server), the permission mode a new agent gets, and how many agents work at once.
struct ServerAgentDefaultsSection: View {
    let server: ServerModel
    let model: ServerSettingsModel
    @State private var folder: String?

    var body: some View {
        SettingsGroup(title: L10n.ServerSettings.Agents.title) {
            SettingsRow(title: L10n.ServerSettings.Folder.title, hint: folder ?? L10n.ServerSettings.Folder.none) {
                Button(L10n.ServerSettings.Folder.choose, action: chooseFolder)
                    .banditoButton(.quiet())
                    .fixedSize()
            }
            if let settings = model.snapshot?.settings {
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.ServerSettings.Approval.title, hint: L10n.ServerSettings.Approval.hint) {
                    SegmentedPicker(
                        selection: Binding(
                            get: { settings.defaultApprovalMode },
                            set: { mode in change(.defaultApprovalMode(mode)) }),
                        options: ApprovalChoice.allCases.map { ($0.mode, $0.title) }
                    )
                    .fixedSize()
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.ServerSettings.MaxRunning.title, hint: L10n.ServerSettings.MaxRunning.hint) {
                    Stepper(
                        value: Binding(
                            get: { settings.maxRunningAgents },
                            set: { count in change(.maxRunningAgents(count)) }),
                        in: ServerSettingLimits.maxRunningAgents
                    ) {
                        Text(
                            settings.maxRunningAgents == 0
                                ? L10n.ServerSettings.MaxRunning.none : "\(settings.maxRunningAgents)"
                        )
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .monospacedDigit()
                        .foregroundStyle(Color.Bandito.text2)
                    }
                    .fixedSize()
                }
            }
        }
        .onAppear { folder = AgentsRootStore.load(serverID: server.id.uuidString) }
    }

    /// The folder the new-agent sheet starts from for this server (`AgentsRootStore`, the same key the sheet reads).
    private func chooseFolder() {
        guard let url = FilePanels.folderURL(message: L10n.ServerSettings.Folder.message) else { return }
        AgentsRootStore.save(url.path, serverID: server.id.uuidString)
        folder = url.path
    }

    private func change(_ change: ServerSettingChange) {
        Task { await model.apply(change) }
    }
}

/// Settings of one server → Maintenance: the server's own updates, the screen's sleep, the database copies, the logs and
/// the report for support.
struct ServerMaintenanceSection: View {
    let server: ServerModel
    let model: ServerSettingsModel
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var copied = false

    var body: some View {
        SettingsGroup(title: L10n.ServerSettings.Maintenance.title) {
            if let settings = model.snapshot?.settings {
                autoUpdateRow(settings)
                Divider().padding(.horizontal, 16)
                screenIdleRow(settings)
                Divider().padding(.horizontal, 16)
                backupEveryRow(settings)
                Divider().padding(.horizontal, 16)
                backupKeepRow(settings)
                Divider().padding(.horizontal, 16)
            }
            if server.supports("backups") {
                backupNowRow
                Divider().padding(.horizontal, 16)
            }
            logsRow
            Divider().padding(.horizontal, 16)
            supportRow
        }
    }

    private func autoUpdateRow(_ settings: ServerSettingValues) -> some View {
        SettingsRow(title: L10n.ServerSettings.AutoUpdate.title, hint: L10n.ServerSettings.AutoUpdate.hint) {
            SegmentedPicker(
                selection: Binding(
                    get: { settings.autoUpdate },
                    set: { mode in change(.autoUpdate(mode)) }),
                options: AutoUpdateMode.allCases.map { ($0, Self.autoUpdateTitle($0)) }
            )
            .fixedSize()
        }
    }

    private func screenIdleRow(_ settings: ServerSettingValues) -> some View {
        SettingsRow(title: L10n.ServerSettings.ScreenIdle.title, hint: L10n.ServerSettings.ScreenIdle.hint) {
            Stepper(
                value: Binding(
                    get: { settings.screenIdleMinutes },
                    set: { minutes in change(.screenIdleMinutes(minutes)) }),
                in: ServerSettingLimits.screenIdleMinutes,
                step: ServerSettingLimits.screenIdleStep
            ) {
                Text(L10n.ServerSettings.minutes(count: settings.screenIdleMinutes))
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .monospacedDigit()
                    .foregroundStyle(Color.Bandito.text2)
            }
            .fixedSize()
        }
    }

    private func backupEveryRow(_ settings: ServerSettingValues) -> some View {
        SettingsRow(title: L10n.ServerSettings.BackupEvery.title, hint: L10n.ServerSettings.BackupEvery.hint) {
            SegmentedPicker(
                selection: Binding(
                    get: { settings.backupEveryHours },
                    set: { hours in change(.backupEveryHours(hours)) }),
                options: ServerSettingLimits.backupEveryHours.map { ($0, Self.backupEveryTitle($0)) }
            )
            .fixedSize()
        }
    }

    private func backupKeepRow(_ settings: ServerSettingValues) -> some View {
        SettingsRow(title: L10n.ServerSettings.BackupKeep.title, hint: L10n.ServerSettings.BackupKeep.hint) {
            Stepper(
                value: Binding(
                    get: { settings.backupKeep },
                    set: { count in change(.backupKeep(count)) }),
                in: ServerSettingLimits.backupKeep
            ) {
                Text(L10n.ServerSettings.copies(count: settings.backupKeep))
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .monospacedDigit()
                    .foregroundStyle(Color.Bandito.text2)
            }
            .fixedSize()
        }
    }

    private var backupNowRow: some View {
        SettingsRow(title: L10n.ServerSettings.BackupNow.title, hint: Self.copyText(model.copyState)) {
            Button(L10n.ServerSettings.BackupNow.button) {
                Task { await model.makeBackupNow() }
            }
            .banditoButton(.quiet())
            .fixedSize()
            .disabled(model.copyState == .working)
        }
    }

    private var logsRow: some View {
        SettingsRow(title: L10n.ServerSettings.Logs.title, hint: L10n.ServerSettings.Logs.hint) {
            Button(L10n.ServerSettings.Logs.open, action: openLogs)
                .banditoButton(.quiet())
                .fixedSize()
        }
    }

    private var supportRow: some View {
        SettingsRow(title: L10n.ServerSettings.Support.title, hint: L10n.ServerSettings.Support.hint) {
            Button(copied ? L10n.ServerSettings.Support.copied : L10n.ServerSettings.Support.copy, action: copyReport)
                .banditoButton(.quiet())
                .fixedSize()
        }
    }

    /// Opens the main window on this server's journal: the logs screen of the Server mode.
    private func openLogs() {
        app.selectedServerID = server.id
        SettingsHandoff.openMainWindow(router: router) { target in
            target.select(mode: .server)
            target.serverSection = .journal
        }
    }

    /// Copies the report for support: versions, the systems and the features, from `ServerSupportReport`.
    private func copyReport() {
        let report = ServerSupportReport.make(
            appVersion: Self.appVersion, appBuild: Self.appBuild, macOS: Self.macOSVersion,
            macArchitecture: Self.architecture, daemon: server.info, host: model.stats)
        SystemActions.copy(report.text)
        copied = true
    }

    private func change(_ change: ServerSettingChange) {
        Task { await model.apply(change) }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    static func autoUpdateTitle(_ mode: AutoUpdateMode) -> String {
        switch mode {
        case .off: L10n.ServerSettings.AutoUpdate.off
        case .notify: L10n.ServerSettings.AutoUpdate.notify
        case .install: L10n.ServerSettings.AutoUpdate.install
        }
    }

    static func backupEveryTitle(_ hours: Int) -> String {
        switch hours {
        case 6: L10n.ServerSettings.BackupEvery.h6
        case 12: L10n.ServerSettings.BackupEvery.h12
        case 48: L10n.ServerSettings.BackupEvery.h48
        case 168: L10n.ServerSettings.BackupEvery.h168
        default: L10n.ServerSettings.BackupEvery.h24
        }
    }

    static func copyText(_ state: ServerSettingsModel.CopyState) -> String? {
        switch state {
        case .idle: L10n.ServerSettings.BackupNow.hint
        case .working: L10n.ServerSettings.BackupNow.working
        case .made(let name): L10n.ServerSettings.BackupNow.made(name: name)
        case .failed: L10n.ServerSettings.BackupNow.failed
        }
    }
}

/// Settings of one server → About the server: the daemon's version and, from `host.stats`, the system, the processor,
/// the memory, the disk and how long the server has run.
struct ServerInfoSection: View {
    let server: ServerModel
    let model: ServerSettingsModel

    var body: some View {
        SettingsGroup(title: L10n.ServerSettings.Info.title) {
            SettingsRow(title: L10n.ServerSettings.Info.daemon) {
                valueText(server.info?.version ?? "—")
            }
            if let stats = model.stats {
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.ServerSettings.Info.system) {
                    valueText(Self.systemText(stats))
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.ServerSettings.Info.cpu) {
                    valueText(L10n.ServerSettings.Info.cores(count: stats.cpus))
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.ServerSettings.Info.memory) {
                    valueText(
                        L10n.ServerSettings.Info.usedOf(
                            used: HostFormat.bytes(stats.memUsed), total: HostFormat.bytes(stats.memTotal)))
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.ServerSettings.Info.disk) {
                    valueText(Self.diskText(stats))
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.ServerSettings.Info.uptime) {
                    valueText(ServerPassport.uptimeText(seconds: stats.uptimeS))
                }
            } else {
                Divider().padding(.horizontal, 16)
                Text(statsNote)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var statsNote: String {
        if !server.supports("host") { L10n.ServerSettings.Info.unavailable }
        else if model.statsFailed { L10n.ServerSettings.Info.statsFailed }
        else { L10n.ServerSettings.loading }
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 13, weight: 400))
            .foregroundStyle(Color.Bandito.text2)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func systemText(_ stats: HostStats) -> String {
        [stats.os, stats.kernel].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The root disk, or the first one the server reports.
    static func diskText(_ stats: HostStats) -> String {
        guard let disk = stats.disks.first(where: { $0.mount == "/" }) ?? stats.disks.first else { return "—" }
        let usage = HostFormat.diskUsage(used: disk.used, total: disk.total)
        return L10n.ServerSettings.Info.usedOf(used: usage.used, total: usage.total)
    }
}
