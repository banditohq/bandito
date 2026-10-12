import Foundation

/// A server the owner can move an agent to or from: `ServerModel` in the app, a fake in the tests. The methods are the
/// `agents.migrate_*` calls of `ServerModel+Migrate.swift`, plus the pause, the list and the delete the process needs.
@MainActor
public protocol MigrationPeer: AnyObject {
    var id: UUID { get }
    /// The server's name as the owner gave it; the source keeps it as `migratedTo` when an agent moves here.
    var serverName: String { get }
    var isConnected: Bool { get }
    func supports(_ feature: String) -> Bool
    func status(of agentId: String) -> AgentStatus
    func setPaused(agentID: String, _ paused: Bool) async throws -> Agent
    func deleteAgent(_ id: String) async throws
    func migrateExport(agentID: String) async throws -> MigrationExport
    func migrateRead(token: String, offset: Int64, length: Int) async throws -> MigrationPiece
    func migrateDone(token: String, movedTo: String?) async throws -> MigrationDone
    func migrateImportBegin(size: Int64, sha256: String) async throws -> String
    func migrateImportWrite(uploadID: String, offset: Int64, data: String) async throws -> Int64
    func migrateImportCommit(uploadID: String, cwd: String?, name: String?) async throws -> MigrationCommit
}

/// Which way the agent's move is: the phases of `AgentMigration`, without their values.
public enum MigrationPhase: String, Sendable, Equatable {
    case pausing, packing, transferring, unpacking, finishing
}

/// Why a move did not finish. Everything before the target's commit is undone on both sides; the cases after it say
/// what is left where.
public enum MigrationFailure: Error, Sendable, Equatable {
    /// The agent kept working or waited for the person for the whole wait, or the daemon refused the export as busy.
    case busy
    /// The person cancelled between two pieces, before the commit. Nothing is left on the target.
    case cancelled
    /// The agent got new events after the export. Reported after the commit: the copy made on the target was deleted
    /// when `copyRemoved` is true. The source is not marked and the agent is running again (unless `sourceLeftPaused`).
    case changedSinceExport(target: String, copyRemoved: Bool)
    /// A daemon refused a step (`reason` is `error.data.reason` when the daemon sent one), or the step itself failed.
    case refused(phase: MigrationPhase, reason: String?, message: String)
    /// One of the two servers does not have the `agent_migrate` feature.
    case unsupported
    /// One of the two servers is not connected.
    case notConnected
}

/// What a finished move leaves behind: the agent on the target and what the person has to look at.
public struct MigrationOutcome: Sendable, Equatable {
    /// The new agent on the target; nil only if the target's commit answered without one.
    public var agent: Agent?
    public var targetName: String
    /// Catalog ids the agent used there that this server does not connect: connect them again.
    public var missingServices: [String]
    /// Settings the target lowered (`["approval_mode"]`: `never` became `risky`).
    public var downgraded: [String]
    /// Entries not moved: the ones the source left out of the archive, plus the ones the target dropped.
    public var skippedCount: Int
    /// Steps of the target's commit that failed after the agent was made.
    public var errors: [MigrationImportError]

    public init(
        agent: Agent?, targetName: String, missingServices: [String] = [], downgraded: [String] = [],
        skippedCount: Int = 0, errors: [MigrationImportError] = []
    ) {
        self.agent = agent
        self.targetName = targetName
        self.missingServices = missingServices
        self.downgraded = downgraded
        self.skippedCount = skippedCount
        self.errors = errors
    }
}

/// The steps of a move: pausing → packing → transferring(fraction) → unpacking → finishing → done | failed.
public enum MigrationStep: Sendable, Equatable {
    case pausing
    case packing
    /// The share of the archive that reached the target, 0…1. Written only when the whole percent changes.
    case transferring(fraction: Double)
    case unpacking
    case finishing
    case done(MigrationOutcome)
    case failed(MigrationFailure)
}

/// Eligible targets and lookups, as pure functions over peers (tested with fakes).
@MainActor
public enum MigrationTargets {
    /// The daemon feature that enables moving an agent (`daemon.info`).
    public static let feature = "agent_migrate"

    /// The other servers an agent of `source` can move to: connected, and both with the feature. Empty when the
    /// source itself lacks the feature.
    public static func eligible<Peer: MigrationPeer>(source: Peer, among peers: [Peer]) -> [Peer] {
        guard source.supports(feature) else { return [] }
        return peers.filter { $0.id != source.id && $0.isConnected && $0.supports(feature) }
    }

    /// The server an agent moved to, by the name the source kept (`migratedTo`). Only when exactly one server has
    /// that name; two servers with one name are not guessed at.
    public static func server<Peer: MigrationPeer>(named name: String, among peers: [Peer]) -> Peer? {
        let matches = peers.filter { $0.serverName == name }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// One move of an agent from `source` to `target`: pause the source, pack it, copy the archive piece by piece, unpack
/// it on the target, then mark the source as moved. Until the target's commit nothing is kept: the archive is dropped
/// on the source and the source is resumed if this move paused it. After the commit the source stays as it is until
/// `agents.migrate_done` with `moved_to` succeeds.
@MainActor
@Observable
public final class AgentMigration {
    public let agentID: String
    public private(set) var step: MigrationStep = .pausing
    /// True when this move paused the source and could not resume it. The person has to resume it by hand.
    public private(set) var sourceLeftPaused = false

    @ObservationIgnored private let source: any MigrationPeer
    @ObservationIgnored private let target: any MigrationPeer
    @ObservationIgnored private let targetFolder: String?
    @ObservationIgnored private let sourceAgentPaused: Bool
    @ObservationIgnored private let chunkSize: Int
    @ObservationIgnored private let busyTimeout: Duration
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let onStep: (@MainActor (MigrationStep) -> Void)?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var phase: MigrationPhase = .pausing
    @ObservationIgnored private var running = false

    /// - Parameters:
    ///   - targetFolder: the project folder on the target (`cwd`); nil lets the agent work in its own folder.
    ///   - sourceAgentPaused: the agent was paused before the move; then the move does not resume it.
    ///   - chunkSize: bytes per `migrate_read`/`migrate_import_write` (1 MiB; the daemon caps it there).
    ///   - busyTimeout: how long to wait for a working or waiting agent to finish its turn after the pause.
    ///   - onStep: called on every step change, for the screen and the tests.
    public init(
        agentID: String, source: any MigrationPeer, target: any MigrationPeer, targetFolder: String?,
        sourceAgentPaused: Bool, chunkSize: Int = 1 << 20, busyTimeout: Duration = .seconds(60),
        pollInterval: Duration = .milliseconds(500),
        onStep: (@MainActor (MigrationStep) -> Void)? = nil
    ) {
        self.agentID = agentID
        self.source = source
        self.target = target
        self.targetFolder = targetFolder
        self.sourceAgentPaused = sourceAgentPaused
        self.chunkSize = max(1, chunkSize)
        self.busyTimeout = busyTimeout
        self.pollInterval = pollInterval
        self.onStep = onStep
    }

    public var isFinished: Bool {
        switch step {
        case .done, .failed: true
        default: false
        }
    }

    /// Asks the move to stop. It takes effect between two pieces, and never after the target's commit.
    public func cancel() {
        cancelRequested = true
    }

    /// Runs the whole move. Returns when it is `done` or `failed`; the state says which.
    public func start() async {
        guard !running, !isFinished else { return }
        running = true
        defer { running = false }
        var token: String?
        var pausedByUs = false
        var committed = false
        do {
            guard source.isConnected, target.isConnected else { throw MigrationFailure.notConnected }
            guard source.supports(MigrationTargets.feature), target.supports(MigrationTargets.feature) else {
                throw MigrationFailure.unsupported
            }

            set(.pausing, phase: .pausing)
            if !sourceAgentPaused {
                _ = try await source.setPaused(agentID: agentID, true)
                pausedByUs = true
            }
            try await waitUntilIdle()
            try checkCancel()

            set(.packing, phase: .packing)
            let export = try await source.migrateExport(agentID: agentID)
            token = export.token
            try checkCancel()

            set(.transferring(fraction: 0), phase: .transferring)
            let uploadID = try await target.migrateImportBegin(size: export.size, sha256: export.sha256)
            try await transfer(export: export, uploadID: uploadID)
            try checkCancel()

            set(.unpacking, phase: .unpacking)
            let commit = try await target.migrateImportCommit(uploadID: uploadID, cwd: targetFolder, name: nil)
            // From here the agent exists on the target. Nothing below may leave it running there as a second copy.
            committed = true

            set(.finishing, phase: .finishing)
            do {
                _ = try await source.migrateDone(token: export.token, movedTo: target.serverName)
            } catch let error as RPCError where error.reason == "changed_since_export" {
                // The agent got new events after the export: undo the copy, drop the archive, resume the source.
                let removed = await removeCopy(commit)
                await rollback(token: export.token, pausedByUs: pausedByUs)
                throw MigrationFailure.changedSinceExport(target: target.serverName, copyRemoved: removed)
            } catch {
                // The copy exists on the target and the source is not marked. The source stays paused, so two live
                // copies never run; the person sees the failure and decides.
                sourceLeftPaused = pausedByUs
                throw failure(from: error)
            }

            let outcome = MigrationOutcome(
                agent: commit.agent, targetName: target.serverName, missingServices: commit.missingServices,
                downgraded: commit.downgraded, skippedCount: export.skipped + commit.skipped.count,
                errors: commit.errors)
            set(.done(outcome), phase: .finishing)
        } catch {
            let failed = failure(from: error)
            if !committed {
                await rollback(token: token, pausedByUs: pausedByUs)
            }
            set(.failed(failed), phase: phase)
        }
    }

    // MARK: steps

    private func set(_ new: MigrationStep, phase newPhase: MigrationPhase) {
        phase = newPhase
        step = new
        onStep?(new)
    }

    private func checkCancel() throws {
        if cancelRequested { throw MigrationFailure.cancelled }
    }

    /// Waits until the agent is neither working nor waiting for the person (the pause interrupts a running turn).
    private func waitUntilIdle() async throws {
        let deadline = ContinuousClock.now.advanced(by: busyTimeout)
        while true {
            try checkCancel()
            let status = source.status(of: agentID)
            if status != .working && status != .needsYou { return }
            if ContinuousClock.now >= deadline { throw MigrationFailure.busy }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Copies the archive from the source to the target piece by piece, in order. Every piece the target took is
    /// counted by its base64 length (no decoding); the target's answer must be the size so far.
    private func transfer(export: MigrationExport, uploadID: String) async throws {
        var offset: Int64 = 0
        var percent = 0
        while true {
            try checkCancel()
            let piece = try await source.migrateRead(token: export.token, offset: offset, length: chunkSize)
            let count = Self.decodedCount(piece.data)
            if count > 0 {
                let written = try await target.migrateImportWrite(uploadID: uploadID, offset: offset, data: piece.data)
                offset += count
                guard written == offset else {
                    throw MigrationFailure.refused(
                        phase: .transferring, reason: "bad_offset", message: "the target wrote \(written), not \(offset)")
                }
                let share = export.size > 0 ? min(100, Int(offset * 100 / export.size)) : 100
                if share != percent {
                    percent = share
                    step = .transferring(fraction: Double(share) / 100)
                    onStep?(step)
                }
            }
            if piece.eof { break }
            guard count > 0 else {
                throw MigrationFailure.refused(phase: .transferring, reason: "stalled", message: "an empty piece before the end")
            }
        }
        guard offset == export.size else {
            throw MigrationFailure.refused(
                phase: .transferring, reason: "size_mismatch", message: "\(offset) of \(export.size) bytes arrived")
        }
    }

    // MARK: undo

    /// Drops the archive on the source and resumes the source if this move paused it. A failed resume is kept in
    /// `sourceLeftPaused`; the failure itself is what the person sees.
    private func rollback(token: String?, pausedByUs: Bool) async {
        if let token {
            _ = try? await source.migrateDone(token: token, movedTo: nil)
        }
        guard pausedByUs else { return }
        do {
            _ = try await source.setPaused(agentID: agentID, false)
            sourceLeftPaused = false
        } catch {
            sourceLeftPaused = true
        }
    }

    /// Deletes the agent the target made. False when it cannot be deleted (or the commit named no agent).
    private func removeCopy(_ commit: MigrationCommit) async -> Bool {
        guard let agent = commit.agent else { return false }
        do {
            try await target.deleteAgent(agent.id)
            return true
        } catch {
            return false
        }
    }

    private func failure(from error: Error) -> MigrationFailure {
        if let failure = error as? MigrationFailure { return failure }
        if error is CancellationError { return .cancelled }
        if let rpc = error as? RPCError {
            if rpc.reason == "agent_busy" { return .busy }
            return .refused(phase: phase, reason: rpc.reason, message: rpc.message)
        }
        return .refused(phase: phase, reason: nil, message: error.localizedDescription)
    }

    /// The decoded length of a base64 string, read from its length and padding only.
    static func decodedCount(_ base64: String) -> Int64 {
        let length = base64.utf8.count
        guard length > 0 else { return 0 }
        let padding = base64.hasSuffix("==") ? 2 : (base64.hasSuffix("=") ? 1 : 0)
        return Int64(length / 4 * 3 - padding)
    }
}
