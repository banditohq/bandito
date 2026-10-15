import CryptoKit
@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Approving a device starts the access cycle at once and keeps it fast for a while.
@MainActor
@Suite struct AccountHubFastAnswerTests {
    private func signedInHub() throws -> AccountHub {
        let keys = MemorySecretStore()
        let session = Session(
            token: "t", user: AccountUser(id: "u1", email: "a@example.com", name: nil, githubLogin: nil),
            device: DeviceRef(id: "mac", approved: true))
        try keys.save(try JSONEncoder().encode(session), account: AccountClient.sessionAccount)
        try SyncKey.save(SymmetricKey(size: .bits256), to: keys)
        let hub = AccountHub(
            keys: keys, dismissed: DismissedServers(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            loadIdentity: { throw URLError(.notConnectedToInternet) })
        hub.accessServers = { [] }
        return hub
    }

    @Test func approvingADeviceRunsTheAccessCycleAtOnceAndOpensTheFastWindow() async throws {
        let hub = try signedInHub()
        #expect(!hub.fastAnswerOpen)
        await hub.deviceApproved()
        #expect(hub.fastAnswerOpen)
        let end = Date().addingTimeInterval(3)
        while hub.accessCycleRuns == 0, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hub.accessCycleRuns == 1)
    }

    @Test func stoppingTheWatchClosesTheWindow() async throws {
        let hub = try signedInHub()
        hub.openFastAnswerWindow()
        #expect(hub.fastAnswerOpen)
        hub.stopWatchingPending()
        #expect(!hub.fastAnswerOpen)
    }

    @Test func aCallDuringARoundIsNotLostButRunsOnce() async throws {
        let hub = try signedInHub()
        async let first: Void = hub.runAccessCycle(configs: [])
        async let second: Void = hub.runAccessCycle(configs: [])
        async let third: Void = hub.runAccessCycle(configs: [])
        _ = await (first, second, third)
        #expect(hub.accessCycleRuns == 2, "the round, and exactly one more for the calls that came meanwhile")
    }

    @Test func aLoneCallRunsOneRound() async throws {
        let hub = try signedInHub()
        await hub.runAccessCycle(configs: [])
        #expect(hub.accessCycleRuns == 1)
    }

    @Test func approvalRunsARoundEvenWhenNothingIsWatching() async throws {
        let hub = try signedInHub()
        await hub.deviceApproved()
        let end = Date().addingTimeInterval(3)
        while hub.accessCycleRuns == 0, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hub.accessCycleRuns >= 1 && hub.fastAnswerOpen)
    }

    @Test func aRequestOpensTheWindowOnceAndAForeignOneNever() throws {
        let hub = try signedInHub()
        hub.noteUnanswered([])
        #expect(!hub.fastAnswerOpen, "a request for another Mac's server is not in the list at all")
        hub.noteUnanswered(["phone|server|1"])
        #expect(hub.fastAnswerOpen)
        hub.stopWatchingPending()
        hub.noteUnanswered(["phone|server|1"])
        #expect(!hub.fastAnswerOpen, "the same request does not open it again")
        hub.noteUnanswered(["phone|server|2"])
        #expect(hub.fastAnswerOpen)
    }
}
