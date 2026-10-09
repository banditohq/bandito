import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@Suite struct AccountClientTests {
    @Test func defaultBaseURLIsTheProductionAPI() {
        #expect(AccountClient.defaultBaseURL.absoluteString == "https://bandito.dev/api/v1")
    }

    @Test func challengeIsPostedWithoutAuthorization() async throws {
        let http = ScriptedHTTP([
            "POST /auth/challenge": [ScriptedReply(#"{"ok":true,"nonce":"n-1","expires_in":300}"#)]
        ])
        let client = try makeClient(http: http)

        let nonce = try await client.challenge()

        #expect(nonce == "n-1")
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try jsonBody(request).isEmpty)
    }

    @Test func emailLoginSendsCodeThenVerifiesWithSignedDeviceAndStoresSession() async throws {
        let identity = try makeIdentity()
        let sessions = MemorySecretStore()
        let http = ScriptedHTTP([
            "POST /auth/email/start": [ScriptedReply(#"{"ok":true}"#)],
            "POST /auth/challenge": [ScriptedReply(#"{"ok":true,"nonce":"n-1","expires_in":300}"#)],
            "POST /auth/email/verify": [ScriptedReply(sessionBody)],
        ])
        let client = try makeClient(http: http, sessions: sessions, identity: identity)

        try await client.emailStart(email: "ann@example.com")
        let session = try await client.emailVerify(email: "ann@example.com", code: "123456")

        #expect(session.token == "tok_1")
        #expect(session.user.email == "ann@example.com")
        #expect(session.user.githubLogin == "ann")
        #expect(session.device == DeviceRef(id: "d1", approved: true))

        let start = try jsonBody(http.requests[0])
        #expect(start["email"] as? String == "ann@example.com")

        let verify = try jsonBody(http.requests[2])
        #expect(verify["email"] as? String == "ann@example.com")
        #expect(verify["code"] as? String == "123456")
        let device = try #require(verify["device"] as? [String: Any])
        #expect(device["name"] as? String == "Test Mac")
        #expect(device["platform"] as? String == "macos")
        try expectValidLoginProof(device, identity: identity, nonce: "n-1")

        #expect(try await client.restoreSession()?.token == "tok_1")
    }

    @Test func githubStartReturnsTheUserCodeAndFlow() async throws {
        let http = ScriptedHTTP([
            "POST /auth/github/start": [
                ScriptedReply(
                    #"{"ok":true,"user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5,"flow_id":"f1"}"#)
            ]
        ])
        let client = try makeClient(http: http)

        let flow = try await client.githubStart()

        #expect(flow.flowID == "f1")
        #expect(flow.userCode == "WDJB-MJHT")
        #expect(flow.verificationURI == URL(string: "https://github.com/login/device"))
        #expect(flow.interval == 5)
        #expect(flow.expiresIn == 900)
    }

    @Test func githubPollSignsAFreshChallengeOnEveryPoll() async throws {
        let identity = try makeIdentity()
        let sessions = MemorySecretStore()
        let http = ScriptedHTTP([
            "POST /auth/challenge": [
                ScriptedReply(#"{"ok":true,"nonce":"n-1","expires_in":300}"#),
                ScriptedReply(#"{"ok":true,"nonce":"n-2","expires_in":300}"#),
                ScriptedReply(#"{"ok":true,"nonce":"n-3","expires_in":300}"#),
            ],
            "POST /auth/github/poll": [
                ScriptedReply(#"{"ok":false,"error":"pending"}"#),
                ScriptedReply(#"{"ok":false,"error":"slow_down","interval":10}"#),
                ScriptedReply(sessionBody),
            ],
        ])
        let client = try makeClient(http: http, sessions: sessions, identity: identity)

        let first = try await client.githubPoll(flowID: "f1")
        let second = try await client.githubPoll(flowID: "f1")
        let third = try await client.githubPoll(flowID: "f1")

        #expect(first == .pending)
        #expect(second == .slowDown(interval: 10))
        guard case .signedIn(let session) = third else {
            Issue.record("expected signedIn, got \(third)")
            return
        }
        #expect(session.token == "tok_1")
        #expect(try await client.restoreSession()?.token == "tok_1")

        let polls = http.requests.filter { $0.url?.path.hasSuffix("/auth/github/poll") == true }
        #expect(polls.count == 3)
        let firstBody = try jsonBody(polls[0])
        let secondBody = try jsonBody(polls[1])
        #expect(firstBody["flow_id"] as? String == "f1")
        try expectValidLoginProof(try #require(firstBody["device"] as? [String: Any]), identity: identity, nonce: "n-1")
        try expectValidLoginProof(try #require(secondBody["device"] as? [String: Any]), identity: identity, nonce: "n-2")
    }

    @Test func githubPollReportsExpiredAndDeniedFlows() async throws {
        let http = ScriptedHTTP([
            "POST /auth/challenge": [ScriptedReply(#"{"ok":true,"nonce":"n","expires_in":300}"#)],
            "POST /auth/github/poll": [
                ScriptedReply(#"{"ok":false,"error":"expired"}"#, status: 410),
                ScriptedReply(#"{"ok":false,"error":"access_denied"}"#, status: 403),
                ScriptedReply(#"{"ok":false,"error":"flow_not_found"}"#, status: 404),
            ],
        ])
        let client = try makeClient(http: http)

        #expect(try await client.githubPoll(flowID: "f1") == .expired)
        #expect(try await client.githubPoll(flowID: "f1") == .denied)
        #expect(try await client.githubPoll(flowID: "f1") == .expired)
    }

    @Test func githubPollThrowsOnBadProofAndGitHubOutage() async throws {
        let http = ScriptedHTTP([
            "POST /auth/challenge": [ScriptedReply(#"{"ok":true,"nonce":"n","expires_in":300}"#)],
            "POST /auth/github/poll": [
                ScriptedReply(#"{"ok":false,"error":"bad_device_proof"}"#, status: 400),
                ScriptedReply(#"{"ok":false,"error":"github_unavailable"}"#, status: 503),
            ],
        ])
        let client = try makeClient(http: http)

        do {
            _ = try await client.githubPoll(flowID: "f1")
            Issue.record("expected bad_device_proof")
        } catch let error as AccountError {
            #expect(error == .api(code: "bad_device_proof", status: 400))
        }
        do {
            _ = try await client.githubPoll(flowID: "f1")
            Issue.record("expected github_unavailable")
        } catch let error as AccountError {
            #expect(error == .api(code: "github_unavailable", status: 503))
        }
    }

    @Test func syncConflictCarriesTheCurrentVersion() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([
            "PUT /sync": [ScriptedReply(#"{"ok":false,"error":"conflict","version":5}"#, status: 409)]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        do {
            _ = try await client.putSync(version: 3, blob: "QUJD")
            Issue.record("expected conflict")
        } catch let error as AccountError {
            #expect(error == .conflict(current: 5))
        }
    }

    @Test func putSyncSendsVersionAndBlobAndReturnsNewVersion() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([
            "PUT /sync": [ScriptedReply(#"{"ok":true,"version":4}"#)]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        let version = try await client.putSync(version: 3, blob: "QUJD")

        #expect(version == 4)
        let body = try jsonBody(http.requests[0])
        #expect(body["version"] as? Int == 3)
        #expect(body["blob"] as? String == "QUJD")
    }

    @Test func getSyncWithoutDataReturnsNil() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([
            "GET /sync": [ScriptedReply(#"{"ok":true,"version":0,"blob":null}"#)]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        #expect(try await client.getSync() == nil)
    }

    @Test func getSyncReturnsVersionAndBlob() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([
            "GET /sync": [ScriptedReply(#"{"ok":true,"version":3,"blob":"QUJD"}"#)]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        #expect(try await client.getSync() == SyncBlob(version: 3, blob: "QUJD"))
    }

    @Test func bearerTokenIsSentOnAuthenticatedCalls() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([
            "GET /me": [
                ScriptedReply(
                    #"{"ok":true,"user":{"id":"u1","email":null,"name":null,"github_login":"ann"},"device":{"id":"d1","approved":true},"devices":[]}"#)
            ]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        _ = try await client.me()

        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer tok_9")
    }

    @Test func meParsesUserDeviceAndDeviceList() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([
            "GET /me": [
                ScriptedReply(
                    """
                    {"ok":true,"user":{"id":"u1","email":"ann@example.com","name":null,"github_login":null},\
                    "device":{"id":"d2","approved":false},\
                    "devices":[{"id":"d2","name":"MacBook","platform":"macos","approved":false,\
                    "created_at":"2026-10-09T10:00:00Z","last_seen_at":"2026-10-09T10:05:00Z","current":true}]}
                    """)
            ]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        let me = try await client.me()

        #expect(me.user.email == "ann@example.com")
        #expect(me.device == DeviceRef(id: "d2", approved: false))
        #expect(me.devices.count == 1)
        #expect(me.devices[0].name == "MacBook")
        #expect(me.devices[0].current)
        #expect(!me.devices[0].approved)
    }

    @Test func meWithoutSessionThrowsNotSignedInWithoutRequest() async throws {
        let http = ScriptedHTTP([:])
        let client = try makeClient(http: http)

        do {
            _ = try await client.me()
            Issue.record("expected notSignedIn")
        } catch let error as AccountError {
            #expect(error == .notSignedIn)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func apiErrorsMapToCodeAndStatusWithReadableText() async throws {
        let http = ScriptedHTTP([
            "POST /auth/email/start": [ScriptedReply(#"{"ok":false,"error":"rate"}"#, status: 429)]
        ])
        let client = try makeClient(http: http)

        do {
            try await client.emailStart(email: "ann@example.com")
            Issue.record("expected rate")
        } catch let error as AccountError {
            #expect(error == .api(code: "rate", status: 429))
            #expect(error.localizedDescription.contains("Too many attempts"))
        }
    }

    @Test func unknownApiCodeKeepsTheCodeInTheDescription() async throws {
        let http = ScriptedHTTP([
            "POST /auth/email/start": [ScriptedReply(#"{"ok":false,"error":"brand_new_code"}"#, status: 500)]
        ])
        let client = try makeClient(http: http)

        do {
            try await client.emailStart(email: "ann@example.com")
            Issue.record("expected an error")
        } catch let error as AccountError {
            #expect(error.localizedDescription.contains("brand_new_code"))
        }
    }

    @Test func deleteDeviceAddsForceOnlyWhenAsked() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([
            "DELETE /devices/d2": [ScriptedReply(#"{"ok":true}"#)],
            "DELETE /devices/d2?force=1": [ScriptedReply(#"{"ok":true}"#)],
        ])
        let client = try makeClient(http: http, sessions: sessions)

        try await client.deleteDevice(id: "d2", force: false)
        try await client.deleteDevice(id: "d2", force: true)

        #expect(http.keys == ["DELETE /devices/d2", "DELETE /devices/d2?force=1"])
    }

    @Test func pendingDevicesAndApproveUseTheApprovedSession() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let approver = try makeIdentity()
        let newDevice = try makeIdentity()
        let pendingJSON = """
            {"ok":true,"devices":[{"id":"d2","name":"iPhone","platform":"ios","public_key":"\(newDevice.publicKeyBase64)","created_at":"2026-10-09T10:00:00Z"}]}
            """
        let http = ScriptedHTTP([
            "GET /devices/pending": [ScriptedReply(pendingJSON)],
            "POST /devices/d2/approve": [ScriptedReply(#"{"ok":true}"#)],
        ])
        let client = try makeClient(http: http, sessions: sessions, identity: approver)

        let pending = try await client.pendingDevices()
        #expect(pending.map(\.id) == ["d2"])
        #expect(pending[0].publicKey == newDevice.publicKeyBase64)

        let syncKey = SymmetricKey(size: .bits256)
        try await client.approve(
            pending[0], confirmedFingerprint: newDevice.fingerprint, syncKey: syncKey, identity: approver)

        let body = try jsonBody(http.requests[1])
        let envelope = try #require(body["envelope"] as? String)
        let opened = try SyncKey.open(envelope: envelope, with: newDevice)
        #expect(rawBytes(of: opened.key) == rawBytes(of: syncKey))
        #expect(opened.senderFingerprint == approver.fingerprint)
    }

    @Test func approveWithAMismatchedFingerprintSendsNothing() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let approver = try makeIdentity()
        let newDevice = try makeIdentity()
        let impostor = try makeIdentity()
        let http = ScriptedHTTP([:])
        let client = try makeClient(http: http, sessions: sessions, identity: approver)
        let pending = PendingDevice(
            id: "d2", name: "iPhone", platform: "ios", publicKey: newDevice.publicKeyBase64,
            createdAt: "2026-10-09T10:00:00Z")

        // The server swapped the key: the code the user reads on the new device is the real one.
        var tampered = Array(newDevice.fingerprint)
        tampered[0] = tampered[0] == "A" ? "B" : "A"
        do {
            try await client.approve(
                pending, confirmedFingerprint: String(tampered),
                syncKey: SymmetricKey(size: .bits256), identity: approver)
            Issue.record("expected fingerprintMismatch")
        } catch let error as AccountError {
            #expect(error == .fingerprintMismatch)
        }
        #expect(http.requests.isEmpty)
        // The code of the impostor's key is not the one the user saw either.
        do {
            try await client.approve(
                pending, confirmedFingerprint: impostor.fingerprint,
                syncKey: SymmetricKey(size: .bits256), identity: approver)
            Issue.record("expected fingerprintMismatch")
        } catch let error as AccountError {
            #expect(error == .fingerprintMismatch)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func approveAcceptsTheCodeWithDifferentCaseAndSpacing() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let approver = try makeIdentity()
        let newDevice = try makeIdentity()
        let http = ScriptedHTTP(["POST /devices/d2/approve": [ScriptedReply(#"{"ok":true}"#)]])
        let client = try makeClient(http: http, sessions: sessions, identity: approver)
        let pending = PendingDevice(
            id: "d2", name: "iPhone", platform: "ios", publicKey: newDevice.publicKeyBase64,
            createdAt: "2026-10-09T10:00:00Z")
        let typed = newDevice.fingerprint.lowercased().replacingOccurrences(of: "-", with: " ")

        try await client.approve(
            pending, confirmedFingerprint: typed, syncKey: SymmetricKey(size: .bits256), identity: approver)

        #expect(http.keys == ["POST /devices/d2/approve"])
    }

    @Test func approveRejectsAPendingKeyThatIsNotX25519() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let approver = try makeIdentity()
        let http = ScriptedHTTP([:])
        let client = try makeClient(http: http, sessions: sessions, identity: approver)
        let pending = PendingDevice(
            id: "d2", name: "iPhone", platform: "ios", publicKey: "cHVi", createdAt: "2026-10-09T10:00:00Z")

        await #expect(throws: SyncKeyError.invalidPublicKey) {
            try await client.approve(
                pending, confirmedFingerprint: "AAAA-AAAA-AAAA-AAAA",
                syncKey: SymmetricKey(size: .bits256), identity: approver)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func deviceIDsThatAreNotSafePathSegmentsAreRejectedBeforeAnyRequest() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let approver = try makeIdentity()
        let newDevice = try makeIdentity()
        let http = ScriptedHTTP([:])
        let client = try makeClient(http: http, sessions: sessions, identity: approver)

        for bad in ["..", "a/b", "", "a?b=1", "a%2Fb", String(repeating: "a", count: 129)] {
            await #expect(throws: AccountError.invalidIdentifier) {
                try await client.deleteDevice(id: bad, force: false)
            }
            let pending = PendingDevice(
                id: bad, name: "x", platform: "ios", publicKey: newDevice.publicKeyBase64,
                createdAt: "2026-10-09T10:00:00Z")
            await #expect(throws: AccountError.invalidIdentifier) {
                try await client.approve(
                    pending, confirmedFingerprint: newDevice.fingerprint,
                    syncKey: SymmetricKey(size: .bits256), identity: approver)
            }
        }
        #expect(http.requests.isEmpty)
    }

    @Test func aDeviceIDOfTheDocumentedShapeIsSentAsIs() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP(["DELETE /devices/abc_DEF-123": [ScriptedReply(#"{"ok":true}"#)]])
        let client = try makeClient(http: http, sessions: sessions)

        try await client.deleteDevice(id: "abc_DEF-123", force: false)

        #expect(http.keys == ["DELETE /devices/abc_DEF-123"])
    }

    @Test func baseURLMustBeBanditoOverHTTPSOrLoopbackOverHTTP() throws {
        let identity = try makeIdentity()
        let sessions = MemorySecretStore()
        #expect(throws: AccountError.insecureBaseURL) {
            try AccountClient(
                identity: identity, sessions: sessions, baseURL: URL(string: "http://evil.example/api/v1")!)
        }
        #expect(throws: AccountError.insecureBaseURL) {
            try AccountClient(
                identity: identity, sessions: sessions, baseURL: URL(string: "https://evil.example/api/v1")!)
        }
        #expect(throws: AccountError.insecureBaseURL) {
            try AccountClient(
                identity: identity, sessions: sessions, baseURL: URL(string: "http://bandito.dev/api/v1")!)
        }
        #expect(throws: AccountError.insecureBaseURL) {
            try AccountClient(
                identity: identity, sessions: sessions, baseURL: URL(string: "https://bandito.dev.evil.example/")!)
        }
        _ = try AccountClient(identity: identity, sessions: sessions, baseURL: AccountClient.defaultBaseURL)
        _ = try AccountClient(
            identity: identity, sessions: sessions, baseURL: URL(string: "http://127.0.0.1:8787/api/v1")!)
        _ = try AccountClient(
            identity: identity, sessions: sessions, baseURL: URL(string: "http://localhost:8787/api/v1")!)
    }

    @Test func sessionDescriptionsDoNotShowTheToken() throws {
        let session = Session(
            token: "tok_secret_value",
            user: AccountUser(id: "u1", email: "ann@example.com", name: "Ann", githubLogin: "ann"),
            device: DeviceRef(id: "d1", approved: true))

        #expect(!"\(session)".contains("tok_secret_value"))
        #expect(!String(reflecting: session).contains("tok_secret_value"))
        #expect("\(session)".contains("<redacted>"))
        #expect(String(reflecting: session).contains("<redacted>"))
    }

    @Test func myEnvelopeIsNilUntilApproved() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([
            "GET /devices/me/envelope": [
                ScriptedReply(#"{"ok":false,"error":"not_yet"}"#, status: 404),
                ScriptedReply(#"{"ok":true,"envelope":"ZW52","from_public_key":"cHVi"}"#),
            ]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        #expect(try await client.myEnvelope() == nil)
        #expect(try await client.myEnvelope() == Envelope(envelope: "ZW52", fromPublicKey: "cHVi"))
    }

    @Test func logoutForgetsTheSessionOnlyAfterTheServerAnswers() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([:])
        let client = try makeClient(http: http, sessions: sessions)

        // No route: the request fails, so the session must survive for a retry.
        do {
            try await client.logout()
            Issue.record("expected a network error")
        } catch let error as AccountError {
            guard case .network = error else {
                Issue.record("expected network, got \(error)")
                return
            }
        }
        #expect(try await client.restoreSession()?.token == "tok_9")
    }

    @Test func logoutClearsTheStoredSession() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([
            "POST /auth/logout": [ScriptedReply(#"{"ok":true}"#)]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        try await client.logout()

        #expect(try await client.restoreSession() == nil)
    }

    @Test func resetConfirmsAndReturnsTheApprovedDevice() async throws {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let http = ScriptedHTTP([
            "POST /account/reset": [ScriptedReply(#"{"ok":true,"device":{"id":"d1","approved":true}}"#)]
        ])
        let client = try makeClient(http: http, sessions: sessions)

        let device = try await client.reset()

        #expect(device == DeviceRef(id: "d1", approved: true))
        #expect(try jsonBody(http.requests[0])["confirm"] as? String == "RESET")
    }
}
