import BanditoDesign
import BanditoKit
import BanditoL10n
import Observation
import SwiftUI

/// Server → Backups: the copies of the server's database, a copy made now, and restoring one. The daemon makes its
/// copies itself and keeps the newest 14 (docs/ARCHITECTURE.md#backups). Shown only on a server with the feature.
struct BackupsView: View {
    let server: ServerModel?
    @State private var model = BackupsModel()
    /// The copy the person chose to restore; the confirmation asks about it.
    @State private var pending: DatabaseBackup?

    var body: some View {
        ServerPage(
            title: L10n.Mode.serverBackups,
            trailing: { createButton },
            content: {
                if let server, server.supports("backups") {
                    Text(L10n.Backups.explain)
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let info = server.info, info.isSafeMode {
                        safeModeBanner(info)
                    }
                    if model.isRestarting {
                        restartingBanner
                    }
                    if let outcome = model.outcome {
                        outcomeBanner(outcome)
                    }
                    if model.phase == .timedOut {
                        Text(L10n.Backups.timedOut)
                            .font(BanditoFont.text(size: 13, weight: 400))
                            .foregroundStyle(Color.Bandito.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let failure = model.failure {
                        UserFacingErrorView(message: failure) {
                            Task { await model.load(server) }
                        }
                    }
                    list(server)
                } else {
                    ServerUnavailable(server: server)
                }
            }
        )
        .task(id: server?.id) {
            // Another server has its own copies: nothing of the old one stays on screen.
            model.reset()
            if let server { await model.load(server) }
        }
        // The list is read again whenever the link comes back, so a restore or a copy made meanwhile shows up.
        .onChange(of: server?.isConnectedNow ?? false) { _, connected in
            if connected, let server {
                Task { await model.load(server) }
            }
        }
        .confirmationDialog(
            pending.map { L10n.Backups.confirmTitle(date: BackupDateLabel.absolute($0.createdAt)) } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Backups.restore, role: .destructive) {
                if let backup = pending, let server {
                    Task { await model.restore(backup, on: server) }
                }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Backups.confirmMessage)
        }
    }

    /// Asks the daemon for a copy now. Nothing to do while a copy or a restore runs, or with no connection.
    private var createButton: some View {
        Button(L10n.Backups.create) {
            if let server { Task { await model.create(server) } }
        }
        .banditoButton(.quiet())
        .fixedSize()
        // Safe mode has no database to copy: only a restore helps.
        .disabled(!canAct || server?.info?.isSafeMode == true)
    }

    /// The daemon runs without a database after a restore: why, and what to do. Restoring a copy below is the way out.
    private func safeModeBanner(_ info: DaemonInfo) -> some View {
        let reason = info.safeModeError ?? info.lastRestore?.error ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Backups.safeMode(error: reason))
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.danger)
            Text(L10n.Backups.safeModeHint)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
            Button(L10n.Backups.leaveSafeMode) {
                if let server { Task { await model.leaveSafeMode(on: server) } }
            }
            .banditoButton(.quiet())
            .fixedSize()
            .disabled(!canAct)
            .padding(.top, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoCard()
    }

    private var canAct: Bool {
        guard let server else { return false }
        return server.isConnectedNow && !model.isBusy
    }

    /// The copies, newest first, in one card. No copies yet: the empty state; still loading: a spinner.
    @ViewBuilder
    private func list(_ server: ServerModel) -> some View {
        if model.backups.isEmpty, model.loaded {
            EmptyState(
                symbol: "clock.arrow.circlepath",
                title: L10n.Backups.emptyTitle,
                message: L10n.Backups.emptyMessage
            )
        } else if model.backups.isEmpty {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.backups.enumerated()), id: \.element.id) { index, backup in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.Bandito.line)
                            .frame(height: 1)
                    }
                    row(backup)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .banditoCard()
            .disabled(model.isRestarting)
        }
    }

    /// One copy: when, why, its size, and the restore link.
    private func row(_ backup: DatabaseBackup) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(BackupDateLabel.short(backup.createdAt, now: Date()))
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(BackupReason(raw: backup.reason).title)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))
                .font(BanditoFont.mono(size: 12))
                .foregroundStyle(Color.Bandito.text2)
            Button(L10n.Backups.restore) {
                pending = backup
            }
            .banditoButton(.link)
            .fixedSize()
            .disabled(!canAct || !BackupReason(raw: backup.reason).canRestore)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// What the last restore came to, once the server was back: the copy restored, the daemon's error, or that the
    /// server did not confirm it.
    private func outcomeBanner(_ outcome: RestoreOutcome) -> some View {
        let text: String
        let tone: Color
        switch outcome {
        case .restored(let copyDate):
            text = L10n.Backups.restoredFrom(date: BackupDateLabel.absolute(copyDate))
            tone = Color.Bandito.text
        case .failed(let error):
            text = L10n.Backups.restoreFailed(error: error)
            tone = Color.Bandito.danger
        case .unknown:
            text = L10n.Backups.restoreUnknown
            tone = Color.Bandito.text2
        }
        return Text(text)
            .font(BanditoFont.text(size: 13, weight: 500))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .banditoCard()
    }

    /// Shown from the moment the restore is asked until the server is back on a new start.
    private var restartingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L10n.Backups.restarting)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoCard()
    }
}

/// The Backups section's state: the list, a copy made now, and a restore that waits for the server to start again.
@MainActor
@Observable
final class BackupsModel {
    enum Phase: Equatable {
        case idle
        /// A copy is being made.
        case creating
        /// The restore is asked; the daemon answers first and then restarts.
        case restoring
        /// The daemon restarts: the link drops and comes back on a new start.
        case restarting
        /// The server did not start again in time.
        case timedOut
    }

    private(set) var backups: [DatabaseBackup] = []
    /// True once the list has been read at least once, so an empty list can show its empty state.
    private(set) var loaded = false
    private(set) var phase: Phase = .idle
    private(set) var failure: UserFacingMessage?
    /// The outcome of the last restore, read from the daemon's record once the server is back.
    private(set) var outcome: RestoreOutcome?

    /// How long to wait for the server to start again after a restore.
    static let restartTimeout: Duration = .seconds(120)

    var isBusy: Bool { phase == .creating || phase == .restoring || phase == .restarting }
    var isRestarting: Bool { phase == .restoring || phase == .restarting }

    /// Forgets what was read from a server: used when the screen moves to another one.
    func reset() {
        backups = []
        loaded = false
        phase = .idle
        failure = nil
        outcome = nil
    }

    /// Reads the list. Does nothing unless the server is connected and has the feature.
    func load(_ server: ServerModel) async {
        guard server.isConnectedNow, server.supports("backups") else { return }
        do {
            backups = try await server.backups()
            loaded = true
            failure = nil
        } catch {
            failure = UserFacingError.message(for: error)
        }
    }

    /// Makes a copy now, then reads the list again.
    func create(_ server: ServerModel) async {
        guard !isBusy, server.isConnectedNow else { return }
        phase = .creating
        failure = nil
        do {
            try await server.createBackup()
            phase = .idle
            await load(server)
        } catch {
            phase = .idle
            failure = UserFacingError.message(for: error)
        }
    }

    /// Asks the daemon to restore `backup`, then waits for the server to come back on a new start.
    /// The start time is compared, not the link alone: an old link that is still up does not count.
    func restore(_ backup: DatabaseBackup, on server: ServerModel) async {
        guard !isBusy, server.isConnectedNow else { return }
        let startedBefore = server.info?.startedAt
        let recordBefore = server.info?.lastRestore
        phase = .restoring
        failure = nil
        outcome = nil
        let requestID: String?
        do {
            requestID = try await server.requestRestore(name: backup.name).id
        } catch {
            phase = .idle
            failure = UserFacingError.message(for: error)
            return
        }
        phase = .restarting
        guard await waitForRestart(server, startedBefore: startedBefore) else { return }
        // The outcome comes from the daemon's record of this request (matched by its id), not from the restart itself.
        outcome = RestoreOutcome.from(
            requested: backup.name,
            requestID: requestID,
            record: server.info?.lastRestore,
            before: recordBefore
        )
        await load(server)
    }

    /// Asks the daemon to leave safe mode. It refuses while the database still does not open (the reason is shown);
    /// otherwise it restarts with the database, and the list is read again.
    func leaveSafeMode(on server: ServerModel) async {
        guard !isBusy, server.isConnectedNow else { return }
        let startedBefore = server.info?.startedAt
        phase = .restoring
        failure = nil
        outcome = nil
        do {
            try await server.leaveSafeMode()
        } catch {
            phase = .idle
            failure = UserFacingError.message(for: error)
            return
        }
        phase = .restarting
        guard await waitForRestart(server, startedBefore: startedBefore) else { return }
        await load(server)
    }

    /// Waits for the server to come back on a new start (its start time changes; an old link that is still up does
    /// not count). Sets the phase to idle, or to timed out after `restartTimeout`.
    private func waitForRestart(_ server: ServerModel, startedBefore: Int64?) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: Self.restartTimeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(1))
            if server.isConnectedNow, let started = server.info?.startedAt, started != startedBefore {
                phase = .idle
                return true
            }
        }
        phase = .timedOut
        return false
    }
}
