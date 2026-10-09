import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@Suite struct AccountRevokeTests {
    private func session(token: String) -> Session {
        Session(
            token: token, user: AccountUser(id: "user-1", email: "me@example.com", name: nil, githubLogin: nil),
            device: DeviceRef(id: "device-1", approved: true))
    }

    @Test func revokeSendsTheGivenTokenWithoutAStoredSession() async throws {
        let sessions = MemorySecretStore()
        let http = ScriptedHTTP(["POST /auth/logout": [ScriptedReply(#"{"ok":true}"#)]])
        let client = try makeClient(http: http, sessions: sessions)

        try await client.revoke(session(token: "tok_old"))

        let auth = http.requests.last?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer tok_old")
    }

    @Test func revokeOfASessionTheServerNoLongerKnowsCountsAsEnded() async throws {
        let http = ScriptedHTTP([
            "POST /auth/logout": [ScriptedReply(#"{"ok":false,"error":"unauthorized"}"#, status: 401)]
        ])
        let client = try makeClient(http: http, sessions: MemorySecretStore())
        try await client.revoke(session(token: "tok_gone"))
    }

    @Test func revokeReportsANetworkFailure() async throws {
        let client = try makeClient(http: ScriptedHTTP([:]), sessions: MemorySecretStore())
        await #expect(throws: AccountError.self) {
            try await client.revoke(session(token: "tok_x"))
        }
    }

    @Test func rotatingTheSyncKeyReplacesTheStoredOne() throws {
        let store = MemorySecretStore()
        let old = try SyncKey.loadOrCreate(from: store)
        let rotated = try SyncKey.rotate(in: store)
        let stored = try SyncKey.load(from: store)
        #expect(rotated.withUnsafeBytes { Data($0) } != old.withUnsafeBytes { Data($0) })
        #expect(stored?.withUnsafeBytes { Data($0) } == rotated.withUnsafeBytes { Data($0) })
    }
}
