import Foundation
import Testing

@testable import BanditoKit

/// A server for the move tests: records every call, and fails where a test tells it to.
@MainActor
final class MigrationFake: MigrationPeer {
    let id = UUID()
    let serverName: String
    var isConnected = true
    var features: Set<String> = [MigrationTargets.feature]

    // Source side
    /// What `status(of:)` answers, one per call; the last one repeats.
    var statuses: [AgentStatus] = [.idle]
    var archive: [UInt8] = []
    var exportSkipped = 0
    var exportError: Error?
    var readError: Error?
    /// Read calls before this count succeed; `readError` is thrown from then on.
    var failReadAfter = Int.max
    var doneError: Error?
    /// Resuming the agent (`paused: false`) fails.
    var setPausedFails = false
    var onRead: (() -> Void)?
    private(set) var pauseCalls: [Bool] = []
    private(set) var exportCalls = 0
    private(set) var doneCalls: [(token: String, movedTo: String?)] = []
    private(set) var readCount = 0
    let exportToken = "tok-1"
    let sourceAgent: Agent

    // Target side
    var beginError: Error?
    var writeError: Error?
    var commitError: Error?
    var commitSkipped: [String] = []
    var commitErrors: [MigrationImportError] = []
    var commitAgentNil = false
    /// Runs when the commit is called, before it answers.
    var onCommit: (() -> Void)?
    var deleteError: Error?
    private(set) var buffer: [UInt8] = []
    private(set) var commitCalls: [(upload: String, cwd: String?)] = []
    private(set) var deletedAgentIDs: [String] = []
    private(set) var beginArgs: (size: Int64, sha256: String)?
    let uploadID = "up-1"
    let targetAgent = Agent(id: "new-1", name: "Forge", runtime: .claude, cwd: "/work/forge")

    init(name: String, sourceAgentID: String = "a") {
        serverName = name
        sourceAgent = Agent(id: sourceAgentID, name: "Forge", runtime: .claude, cwd: "/p")
    }

    func supports(_ feature: String) -> Bool { features.contains(feature) }

    func status(of agentId: String) -> AgentStatus {
        guard statuses.count > 1 else { return statuses[0] }
        return statuses.removeFirst()
    }

    func setPaused(agentID: String, _ paused: Bool) async throws -> Agent {
        pauseCalls.append(paused)
        if !paused && setPausedFails { throw refusal("io") }
        return sourceAgent
    }

    func deleteAgent(_ id: String) async throws {
        if let deleteError { throw deleteError }
        deletedAgentIDs.append(id)
    }

    func migrateExport(agentID: String) async throws -> MigrationExport {
        exportCalls += 1
        if let exportError { throw exportError }
        return MigrationExport(
            token: exportToken, size: Int64(archive.count), sha256: "abc", files: 2, events: 5, skipped: exportSkipped)
    }

    func migrateRead(token: String, offset: Int64, length: Int) async throws -> MigrationPiece {
        readCount += 1
        onRead?()
        if readCount > failReadAfter, let readError { throw readError }
        let start = Int(offset)
        let end = min(archive.count, start + length)
        let slice = start < end ? Data(archive[start..<end]) : Data()
        return MigrationPiece(data: slice.base64EncodedString(), eof: end >= archive.count)
    }

    func migrateDone(token: String, movedTo: String?) async throws -> MigrationDone {
        doneCalls.append((token, movedTo))
        if let doneError { throw doneError }
        return MigrationDone(ok: true, agent: movedTo == nil ? nil : sourceAgent)
    }

    func migrateImportBegin(size: Int64, sha256: String) async throws -> String {
        beginArgs = (size, sha256)
        if let beginError { throw beginError }
        return uploadID
    }

    func migrateImportWrite(uploadID: String, offset: Int64, data: String) async throws -> Int64 {
        if let writeError { throw writeError }
        guard offset == Int64(buffer.count), let bytes = Data(base64Encoded: data) else {
            throw RPCError(code: RPCError.commandsError, message: "bad offset", data: .object(["reason": .string("bad_offset")]))
        }
        buffer += bytes
        return Int64(buffer.count)
    }

    func migrateImportCommit(uploadID: String, cwd: String?, name: String?) async throws -> MigrationCommit {
        commitCalls.append((uploadID, cwd))
        onCommit?()
        if let commitError { throw commitError }
        return MigrationCommit(
            agent: commitAgentNil ? nil : targetAgent, missingServices: ["notion"], downgraded: ["approval_mode"],
            skipped: commitSkipped, errors: commitErrors)
    }
}

/// A `daemon`-style refusal with `error.data.reason`.
private func refusal(_ reason: String) -> RPCError {
    RPCError(code: RPCError.commandsError, message: reason, data: .object(["reason": .string(reason)]))
}

private func bytes(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8($0 % 251) }
}

@MainActor
private func makeMigration(
    source: MigrationFake, target: MigrationFake, sourceAgentPaused: Bool = false, chunkSize: Int = 4,
    busyTimeout: Duration = .seconds(1), onStep: (@MainActor (MigrationStep) -> Void)? = nil
) -> AgentMigration {
    AgentMigration(
        agentID: "a", source: source, target: target, targetFolder: "/work/forge",
        sourceAgentPaused: sourceAgentPaused, chunkSize: chunkSize, busyTimeout: busyTimeout,
        pollInterval: .milliseconds(1), onStep: onStep)
}

@Suite(.serialized) @MainActor struct AgentMigrationTests {
    // MARK: happy path

    @Test func movesTheArchiveAndMarksTheSource() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(10)
        source.exportSkipped = 1
        let target = MigrationFake(name: "Server")
        target.commitSkipped = ["x.png: too big"]
        var seen: [MigrationStep] = []
        let migration = makeMigration(source: source, target: target, chunkSize: 4) { seen.append($0) }

        await migration.start()

        #expect(migration.isFinished)
        #expect(source.pauseCalls == [true])
        #expect(target.beginArgs?.size == 10)
        #expect(target.beginArgs?.sha256 == "abc")
        #expect(target.buffer == source.archive)
        #expect(target.commitCalls.count == 1)
        #expect(target.commitCalls.first?.cwd == "/work/forge")
        #expect(source.doneCalls.count == 1)
        #expect(source.doneCalls.first?.token == "tok-1")
        #expect(source.doneCalls.first?.movedTo == "Server")
        #expect(migration.sourceLeftPaused == false)

        let order = seen.map { step -> String in
            switch step {
            case .pausing: "pausing"
            case .packing: "packing"
            case .transferring: "transferring"
            case .unpacking: "unpacking"
            case .finishing: "finishing"
            case .done: "done"
            case .failed: "failed"
            }
        }
        let collapsed = order.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        #expect(collapsed == ["pausing", "packing", "transferring", "unpacking", "finishing", "done"])

        guard case .done(let outcome) = migration.step else {
            Issue.record("expected done, got \(migration.step)")
            return
        }
        #expect(outcome.agent?.id == "new-1")
        #expect(outcome.targetName == "Server")
        #expect(outcome.missingServices == ["notion"])
        #expect(outcome.downgraded == ["approval_mode"])
        #expect(outcome.skippedCount == 2)
    }

    @Test func leavesAnAlreadyPausedAgentPaused() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(3)
        let target = MigrationFake(name: "Server")
        let migration = makeMigration(source: source, target: target, sourceAgentPaused: true)

        await migration.start()

        #expect(migration.isFinished)
        #expect(source.pauseCalls.isEmpty)
    }

    // MARK: rollback on every step before the commit

    @Test func rollsBackWhenAnyStepBeforeTheCommitFails() async {
        enum Break: CaseIterable { case export, read, begin, write, commit }
        for point in Break.allCases {
            let source = MigrationFake(name: "Mac")
            source.archive = bytes(9)
            let target = MigrationFake(name: "Server")
            let error = refusal("io")
            switch point {
            case .export: source.exportError = error
            case .read:
                source.readError = error
                source.failReadAfter = 1
            case .begin: target.beginError = error
            case .write: target.writeError = error
            case .commit: target.commitError = error
            }
            let migration = makeMigration(source: source, target: target)

            await migration.start()

            guard case .failed(let failure) = migration.step else {
                Issue.record("\(point): expected failed, got \(migration.step)")
                continue
            }
            if case .refused(_, let reason, _) = failure {
                #expect(reason == "io", "\(point)")
            } else {
                Issue.record("\(point): expected refused, got \(failure)")
            }
            // Nothing is marked as moved, and the source is resumed because this move paused it.
            #expect(source.doneCalls.allSatisfy { $0.movedTo == nil }, "\(point)")
            #expect(source.pauseCalls == [true, false], "\(point)")
            #expect(migration.sourceLeftPaused == false, "\(point)")
            #expect(target.deletedAgentIDs.isEmpty, "\(point)")
            // The archive is dropped on the source once it exists.
            if point == .export {
                #expect(source.doneCalls.isEmpty, "\(point)")
            } else {
                #expect(source.doneCalls.count == 1, "\(point)")
                #expect(source.doneCalls.first?.token == "tok-1", "\(point)")
            }
        }
    }

    @Test func aFailureBeforeTheCommitDoesNotResumeAnAlreadyPausedAgent() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(5)
        let target = MigrationFake(name: "Server")
        target.commitError = refusal("io")
        let migration = makeMigration(source: source, target: target, sourceAgentPaused: true)

        await migration.start()

        #expect(source.pauseCalls.isEmpty)
        #expect(source.doneCalls.first?.movedTo == nil)
    }

    @Test func aFailedResumeIsReportedAsLeftPaused() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(5)
        let target = MigrationFake(name: "Server")
        target.commitError = refusal("io")
        let migration = makeMigration(source: source, target: target)
        source.setPausedFails = true

        await migration.start()

        #expect(migration.sourceLeftPaused)
        guard case .failed = migration.step else {
            Issue.record("expected failed")
            return
        }
    }

    // MARK: busy agent

    @Test func waitsForAWorkingAgentThenMoves() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(4)
        source.statuses = [.working, .needsYou, .idle]
        let target = MigrationFake(name: "Server")
        let migration = makeMigration(source: source, target: target)

        await migration.start()

        #expect(source.doneCalls.first?.movedTo == "Server")
        #expect(migration.isFinished)
    }

    @Test func givesUpWhenTheAgentStaysBusy() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(4)
        source.statuses = [.working]
        let target = MigrationFake(name: "Server")
        let migration = makeMigration(source: source, target: target, busyTimeout: .milliseconds(30))

        await migration.start()

        #expect(migration.step == .failed(.busy))
        #expect(source.exportCalls == 0)
        #expect(target.beginArgs == nil)
        #expect(source.pauseCalls == [true, false])
    }

    @Test func busyRefusalFromTheExportIsBusy() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(4)
        source.exportError = refusal("agent_busy")
        let target = MigrationFake(name: "Server")
        let migration = makeMigration(source: source, target: target)

        await migration.start()

        #expect(migration.step == .failed(.busy))
        #expect(source.pauseCalls == [true, false])
    }

    // MARK: cancel

    @Test func cancelBetweenPiecesRollsBack() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(40)
        let target = MigrationFake(name: "Server")
        let migration = makeMigration(source: source, target: target, chunkSize: 4)
        source.onRead = { [weak migration] in
            if source.readCount == 2 { migration?.cancel() }
        }

        await migration.start()

        #expect(migration.step == .failed(.cancelled))
        #expect(source.readCount == 2)
        #expect(target.commitCalls.isEmpty)
        #expect(source.doneCalls.first?.movedTo == nil)
        #expect(source.pauseCalls == [true, false])
    }

    // MARK: changed since export

    @Test func changedSinceExportDeletesTheCopyAndResumesTheSource() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(6)
        source.doneError = refusal("changed_since_export")
        let target = MigrationFake(name: "Server")
        let migration = makeMigration(source: source, target: target)

        await migration.start()

        #expect(migration.step == .failed(.changedSinceExport(target: "Server", copyRemoved: true)))
        #expect(target.deletedAgentIDs == ["new-1"])
        #expect(source.doneCalls.count == 2)
        #expect(source.doneCalls.last?.movedTo == nil)
        #expect(source.doneCalls.last?.token == "tok-1")
        #expect(source.pauseCalls == [true, false])
        #expect(migration.sourceLeftPaused == false)
    }

    @Test func changedSinceExportReportsAFailedDelete() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(6)
        source.doneError = refusal("changed_since_export")
        let target = MigrationFake(name: "Server")
        target.deleteError = refusal("io")
        let migration = makeMigration(source: source, target: target)

        await migration.start()

        #expect(migration.step == .failed(.changedSinceExport(target: "Server", copyRemoved: false)))
    }

    @Test func otherDoneFailureKeepsTheSourcePausedAndTheCopy() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(6)
        source.doneError = refusal("io")
        let target = MigrationFake(name: "Server")
        let migration = makeMigration(source: source, target: target)

        await migration.start()

        guard case .failed(.refused(let phase, let reason, _)) = migration.step else {
            Issue.record("expected refused, got \(migration.step)")
            return
        }
        #expect(phase == .finishing)
        #expect(reason == "io")
        #expect(target.deletedAgentIDs.isEmpty)
        #expect(source.pauseCalls == [true])
        #expect(migration.sourceLeftPaused)
    }

    // MARK: outcome details

    @Test func commitWithoutAgentStillMarksTheSource() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(6)
        let target = MigrationFake(name: "Server")
        target.commitAgentNil = true
        let migration = makeMigration(source: source, target: target)

        await migration.start()

        #expect(source.doneCalls.last?.movedTo == "Server")
        guard case .done(let outcome) = migration.step else {
            Issue.record("expected done")
            return
        }
        #expect(outcome.agent == nil)
    }

    @Test func commitErrorsAreCarriedToTheOutcome() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(6)
        let target = MigrationFake(name: "Server")
        target.commitErrors = [MigrationImportError(step: "schedule", message: "bad cron", index: 0)]
        let migration = makeMigration(source: source, target: target)

        await migration.start()

        guard case .done(let outcome) = migration.step else {
            Issue.record("expected done")
            return
        }
        #expect(outcome.errors == [MigrationImportError(step: "schedule", message: "bad cron", index: 0)])
    }

    @Test func refusesWhenAServerIsNotConnectedOrLacksTheFeature() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(6)
        let target = MigrationFake(name: "Server")
        target.isConnected = false
        let migration = makeMigration(source: source, target: target)
        await migration.start()
        #expect(migration.step == .failed(.notConnected))
        #expect(source.pauseCalls.isEmpty)

        let older = MigrationFake(name: "Old")
        older.features = []
        let second = makeMigration(source: source, target: older)
        await second.start()
        #expect(second.step == .failed(.unsupported))
        #expect(source.pauseCalls.isEmpty)
    }

    // MARK: progress

    @Test func progressIsWrittenOncePerWholePercent() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(1000)
        let target = MigrationFake(name: "Server")
        var fractions: [Double] = []
        let migration = makeMigration(source: source, target: target, chunkSize: 1) { step in
            if case .transferring(let fraction) = step { fractions.append(fraction) }
        }

        await migration.start()

        #expect(source.readCount == 1000)
        // 0 when the transfer starts, then 1 % … 100 %: one write per whole percent, not per piece.
        #expect(fractions.count == 101)
        #expect(fractions.first == 0)
        #expect(fractions.last == 1)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func cancelAfterTheCommitIsIgnored() async {
        let source = MigrationFake(name: "Mac")
        source.archive = bytes(6)
        let target = MigrationFake(name: "Server")
        let migration = makeMigration(source: source, target: target)
        target.onCommit = { [weak migration] in migration?.cancel() }

        await migration.start()

        #expect(source.doneCalls.last?.movedTo == "Server")
        guard case .done = migration.step else {
            Issue.record("expected done, got \(migration.step)")
            return
        }
    }

    // MARK: helpers

    @Test func decodedLengthComesFromTheBase64Text() {
        #expect(AgentMigration.decodedCount("") == 0)
        #expect(AgentMigration.decodedCount("QQ==") == 1)
        #expect(AgentMigration.decodedCount("QUI=") == 2)
        #expect(AgentMigration.decodedCount("QUJD") == 3)
        let data = Data(bytes(1000))
        #expect(AgentMigration.decodedCount(data.base64EncodedString()) == 1000)
    }

    @Test func eligibleTargetsAreOtherConnectedServersWithTheFeature() {
        let source = MigrationFake(name: "Mac")
        let good = MigrationFake(name: "Server")
        let offline = MigrationFake(name: "Offline")
        offline.isConnected = false
        let old = MigrationFake(name: "Old")
        old.features = []
        let peers = [source, good, offline, old]

        let eligible = MigrationTargets.eligible(source: source, among: peers)
        #expect(eligible.map(\.id) == [good.id])

        source.features = []
        #expect(MigrationTargets.eligible(source: source, among: peers).isEmpty)
    }

    @Test func movedToIsLookedUpByNameOnlyWhenUnique() {
        let a = MigrationFake(name: "Server")
        let b = MigrationFake(name: "Server")
        let c = MigrationFake(name: "Laptop")
        #expect(MigrationTargets.server(named: "Laptop", among: [a, c])?.id == c.id)
        #expect(MigrationTargets.server(named: "Server", among: [a, b, c]) == nil)
        #expect(MigrationTargets.server(named: "Nope", among: [a, c]) == nil)
    }

    // MARK: wire

    @Test func repliesDecodeWithTheSnakeCaseDecoder() throws {
        let export = #"{"token":"t","size":12,"sha256":"ff","files":2,"events":3,"skipped":1}"#
        let decodedExport = try RPCClient.decoder.decode(MigrationExport.self, from: Data(export.utf8))
        #expect(decodedExport == MigrationExport(token: "t", size: 12, sha256: "ff", files: 2, events: 3, skipped: 1))

        let piece = #"{"data":"QQ==","eof":true}"#
        #expect(try RPCClient.decoder.decode(MigrationPiece.self, from: Data(piece.utf8)).eof)

        let commit = """
            {"agent":null,"missing_services":["notion"],"granted_services":[],"downgraded":["approval_mode"],
             "skipped":["a.bin: too big"],"schedule_ids":["s1"],"events":4,"files":2,
             "errors":[{"step":"schedule","message":"bad cron","index":1}]}
            """
        let decoded = try RPCClient.decoder.decode(MigrationCommit.self, from: Data(commit.utf8))
        #expect(decoded.agent == nil)
        #expect(decoded.missingServices == ["notion"])
        #expect(decoded.downgraded == ["approval_mode"])
        #expect(decoded.skipped == ["a.bin: too big"])
        #expect(decoded.scheduleIds == ["s1"])
        #expect(decoded.errors == [MigrationImportError(step: "schedule", message: "bad cron", index: 1)])
    }

    @Test func agentDecodesMigratedFields() throws {
        let moved = #"{"id":"a","name":"n","runtime":"claude","cwd":"/x","paused":true,"migrated_to":"Server","migrated_at":1700}"#
        let agent = try RPCClient.decoder.decode(Agent.self, from: Data(moved.utf8))
        #expect(agent.migratedTo == "Server")
        #expect(agent.migratedAt == 1700)

        let plain = #"{"id":"a","name":"n","runtime":"claude","cwd":"/x"}"#
        let old = try RPCClient.decoder.decode(Agent.self, from: Data(plain.utf8))
        #expect(old.migratedTo == nil)
        #expect(old.migratedAt == nil)
    }
}
