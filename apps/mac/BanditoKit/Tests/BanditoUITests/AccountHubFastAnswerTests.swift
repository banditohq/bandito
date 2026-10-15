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
}
