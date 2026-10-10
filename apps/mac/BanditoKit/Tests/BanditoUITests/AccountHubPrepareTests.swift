import BanditoKit
import Foundation
import Testing

@testable import BanditoUI
@testable import BanditoKit

/// Counts how often the device identity is read.
@MainActor
final class IdentityLoads {
    var count = 0
}

@MainActor
@Suite struct AccountHubPrepareTests {
    struct LoadFailed: Error {}

    @Test func callsMadeTogetherShareOneLoadAndOneClient() async throws {
        let loads = IdentityLoads()
        let hub = AccountHub(keys: MemorySecretStore(), loadIdentity: {
            await MainActor.run { loads.count += 1 }
            try await Task.sleep(for: .milliseconds(20))
            return try DeviceIdentity.make(from: MemorySecretStore())
        })
        async let first = hub.prepare()
        async let second = hub.prepare()
        let (a, b) = try await (first, second)
        #expect(a === b)
        #expect(loads.count == 1)
        #expect(hub.client === a)
    }

    @Test func aFailedLoadReachesEveryCallAndTheNextCallTriesAgain() async throws {
        let loads = IdentityLoads()
        let hub = AccountHub(keys: MemorySecretStore(), loadIdentity: {
            await MainActor.run { loads.count += 1 }
            try await Task.sleep(for: .milliseconds(20))
            throw LoadFailed()
        })
        let first = Task { try await hub.prepare() }
        let second = Task { try await hub.prepare() }
        await #expect(throws: LoadFailed.self) { try await first.value }
        await #expect(throws: LoadFailed.self) { try await second.value }
        #expect(loads.count == 1)
        await #expect(throws: LoadFailed.self) { try await hub.prepare() }
        #expect(loads.count == 2)
    }
}
