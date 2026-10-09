import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoUI

/// A server whose job reads fail where the test says so. Replies are used in order.
@MainActor
private final class FakeSetupServer: SetupServer {
    enum Reply {
        case job(String)
        case failure
    }

    var replies: [Reply]
    private(set) var jobReads = 0

    init(replies: [Reply]) {
        self.replies = replies
    }

    /// The status after an install: nothing is missing any more.
    func setupStatus() async throws -> SetupStatus {
        let json = #"{"os":"linux","arch":"x86_64","sudo":"none","components":[],"features":{"screen":"ready","browser":"ready","containers":"ready","agents":{"claude":"ready","codex":"ready","grok":"ready"}}}"#
        return try Self.decoder.decode(SetupStatus.self, from: Data(json.utf8))
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func setupInstall(components: [String]) async throws -> String {
        "job-1"
    }

    func setupJob(_ id: String, from offset: UInt64) async throws -> SetupJob {
        jobReads += 1
        guard !replies.isEmpty else { throw FakeError.unused }
        switch replies.removeFirst() {
        case .job(let json):
            return try Self.decoder.decode(SetupJob.self, from: Data(json.utf8))
        case .failure:
            throw FakeError.lostConnection
        }
    }

    enum FakeError: Error {
        case unused
        case lostConnection
    }
}

private let runningJob = #"{"state":"running","step":"Installing claude","log":"npm: added 1 package\n","offset":24}"#
private let doneJob = #"{"state":"done","step":"Done","log":"","offset":24}"#

@MainActor
@Suite struct SetupInstallTests {
    @Test func aJobReadThatFailsOnceIsReadAgainAndTheInstallEnds() async {
        let server = FakeSetupServer(replies: [.job(runningJob), .failure, .job(doneJob)])
        let setup = SetupModel()
        setup.pollInterval = .milliseconds(1)
        await setup.install(["claude"], server: server)
        #expect(setup.job?.state == .done)
        #expect(setup.error == nil)
        #expect(!setup.isRunning)
        #expect(server.jobReads == 3)
    }

    @Test func aJobThatCannotBeReadIsDroppedNotLeftRunning() async {
        let server = FakeSetupServer(replies: [.job(runningJob), .failure, .failure])
        let setup = SetupModel()
        setup.pollInterval = .milliseconds(1)
        await setup.install(["claude"], server: server)
        #expect(setup.job == nil)
        #expect(setup.error != nil)
        #expect(!setup.isRunning)
    }
}
