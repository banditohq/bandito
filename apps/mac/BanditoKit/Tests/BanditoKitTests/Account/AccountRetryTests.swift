import Foundation
import Testing

@testable import BanditoKit

@Suite struct AccountRetryTests {
    private let nonce = ScriptedReply(#"{"ok":true,"nonce":"n-1","expires_in":300}"#)

    @Test func aReadThatLosesItsConnectionOnceSucceedsOnTheRetry() async throws {
        let http = ScriptedHTTP([
            "POST /auth/challenge": [.fail(.networkConnectionLost), nonce]
        ])
        let nonce = try await makeClient(http: http).challenge()
        #expect(nonce == "n-1")
        #expect(http.keys.count == 2)
    }

    @Test func aReadGivesUpAfterTwoRetriesWithTheErrorCode() async throws {
        let http = ScriptedHTTP(["GET /me": [.fail(.networkConnectionLost)]])
        let client = try makeClient(http: http, sessions: try storedSession())
        await #expect(throws: AccountError.network("NSURLErrorDomain -1005")) { _ = try await client.me() }
        #expect(http.keys.count == 3)
    }

    @Test func aGatewayErrorOnAReadIsTriedAgain() async throws {
        let ok = ScriptedReply(#"{"ok":true,"version":0,"blob":null}"#)
        let http = ScriptedHTTP(["GET /sync": [ScriptedReply("<html>", status: 502), ok]])
        let client = try makeClient(http: http, sessions: try storedSession())
        #expect(try await client.getSync() == nil)
        #expect(http.keys.count == 2)
    }

    @Test func aWriteIsNotRepeatedAfterADroppedConnection() async throws {
        let http = ScriptedHTTP(["PUT /sync": [.fail(.networkConnectionLost)]])
        let client = try makeClient(http: http, sessions: try storedSession())
        await #expect(throws: AccountError.self) { _ = try await client.putSync(version: 1, blob: "x") }
        #expect(http.keys.count == 1)
    }

    @Test func aWriteIsRepeatedWhenTheRequestNeverLeftThePhone() async throws {
        let http = ScriptedHTTP(["POST /auth/email/start": [.fail(.cannotConnectToHost), ScriptedReply(#"{"ok":true}"#)]])
        try await makeClient(http: http).emailStart(email: "ann@example.com")
        #expect(http.keys.count == 2)
    }

    @Test func verifyRetriesWithAFreshChallengeAfterADroppedConnection() async throws {
        let http = ScriptedHTTP([
            "POST /auth/challenge": [nonce, ScriptedReply(#"{"ok":true,"nonce":"n-2","expires_in":300}"#)],
            "POST /auth/email/verify": [.fail(.networkConnectionLost), ScriptedReply(sessionBody)],
        ])
        let session = try await makeClient(http: http).emailVerify(email: "ann@example.com", code: "123456")
        #expect(session.token == "tok_1")
        let nonces = try http.requests.filter { $0.url?.path.hasSuffix("/email/verify") == true }.map {
            ((try jsonBody($0)["device"]) as? [String: Any])?["nonce"] as? String
        }
        #expect(nonces == ["n-1", "n-2"])
    }

    @Test func verifyThatFindsTheCodeSpentAfterALostAnswerSaysSo() async throws {
        let http = ScriptedHTTP([
            "POST /auth/challenge": [nonce],
            "POST /auth/email/verify": [.fail(.networkConnectionLost), ScriptedReply(#"{"ok":false,"error":"code_invalid"}"#, status: 401)],
        ])
        await #expect(throws: AccountError.api(code: AccountClient.verifyUnconfirmed, status: 0)) {
            _ = try await makeClient(http: http).emailVerify(email: "ann@example.com", code: "123456")
        }
    }

    @Test func aWrongCodeWithoutAnyDropIsStillAWrongCode() async throws {
        let http = ScriptedHTTP([
            "POST /auth/challenge": [nonce],
            "POST /auth/email/verify": [ScriptedReply(#"{"ok":false,"error":"code_invalid"}"#, status: 401)],
        ])
        await #expect(throws: AccountError.api(code: "code_invalid", status: 401)) {
            _ = try await makeClient(http: http).emailVerify(email: "ann@example.com", code: "123456")
        }
    }

    @Test func theAccountSessionWaitsForTheNetwork() {
        let configuration = URLSessionHTTPClient.accountConfiguration()
        #expect(configuration.waitsForConnectivity)
        #expect(configuration.timeoutIntervalForResource == 30)
    }

    private func storedSession() throws -> MemorySecretStore {
        let store = MemorySecretStore()
        try store.save(Data(sessionBody.utf8), account: AccountClient.sessionAccount)
        return store
    }
}
