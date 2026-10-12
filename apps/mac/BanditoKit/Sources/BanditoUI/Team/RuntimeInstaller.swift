import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import Observation
import SwiftUI

/// Installs a missing agent CLI from the New agent sheet, with the same `setup.*` calls the first-run subscriptions step
/// and Server → Overview use. The sheet asks it whether a card may offer "Install" and shows its progress and failure.
@MainActor
@Observable
final class RuntimeInstaller {
    /// The server's setup status and the running install job.
    let setup = SetupModel()
    /// The runtime whose install is running, if any. One install at a time.
    /// Only `install` sets it, and the layout audit to draw a running install.
    internal(set) var installing: RuntimeKind?
    /// The runtime whose last install did not finish: its card says so and keeps the link to the manual guide.
    internal(set) var failed: RuntimeKind?

    /// Reads which CLIs the server can install. A failed read leaves no "Install" button: the guide link stays.
    func load(_ server: SetupServer) async {
        await setup.load(server)
    }

    /// Runtimes offered without a status read: the layout audit draws the button this way.
    @ObservationIgnored var offeredForAudit: Set<RuntimeKind> = []

    /// The server lacks `kind` and Bandito has an installer for it there.
    func canInstall(_ kind: RuntimeKind) -> Bool {
        if offeredForAudit.contains(kind) { return true }
        guard let component = setup.status?.components.first(where: { $0.id == kind.rawValue }) else { return false }
        return !component.installed && component.installable
    }

    /// The last line the install printed: what it is doing now.
    var lastLine: String? {
        InstallLog.lastLine(setup.log.isEmpty ? (setup.job?.step ?? "") : setup.log)
    }

    /// Installs `kind`, then reads the runtimes again (`refresh`) so the card turns to "Sign-in needed" or "Ready".
    /// A job that needs the administrator's password, fails, or cannot be read counts as failed.
    func install(_ kind: RuntimeKind, server: SetupServer, refresh: () async -> Void) async {
        guard installing == nil, !setup.isRunning else { return }
        installing = kind
        failed = nil
        defer { installing = nil }
        await setup.install([kind.rawValue], server: server)
        let state = setup.job?.state
        if setup.error != nil || state == .failed || state == .needsPassword || state == .running {
            failed = kind
        }
        await refresh()
        await setup.load(server)
    }
}

/// Under a runtime card that says "Not installed": "Install" for a CLI Bandito can install on the server, the progress
/// while it runs, and what went wrong. Nothing for a CLI it cannot install: the card keeps its link to the guide.
struct RuntimeInstallRow: View {
    var installer: RuntimeInstaller
    let kind: RuntimeKind
    let name: String
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if installer.installing == kind {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                    Text(installer.lastLine ?? L10n.Onboarding.Subs.installing)
                        .font(BanditoFont.mono(size: 11, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                if installer.failed == kind {
                    Text(L10n.Onboarding.Subs.installFailed(name: name))
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if installer.canInstall(kind) {
                    Button(L10n.Setup.install, action: install)
                        .font(BanditoFont.text(size: 11.5, weight: 500))
                        .banditoButton(.link)
                        .disabled(installer.installing != nil)
                }
            }
        }
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
