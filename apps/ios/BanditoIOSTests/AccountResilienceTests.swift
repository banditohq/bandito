import BanditoKit
import Foundation
import Testing

@testable import Bandito

/// Answers by `METHOD /path`; a script entry may be a transport failure. Each route answers its entries in order and
/// repeats the last.
private final class FlakyServer: HTTPClient, @unchecked Sendable {
    // @unchecked: `routes` and `count` are guarded by `lock`.
    private let lock = NSLock()
    private var routes: [String: [Result<(Int, String), URLError>]] = [:]
    private var counts: [String: Int] = [:]

    func script(_ key: String, _ entries: [Result<(Int, String), URLError>]) { lock.withLock { routes[key] = entries } }
    func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path.replacingOccurrences(of: "/api/v1", with: "") ?? ""
        let key = "\(request.httpMethod ?? "GET") \(path)"
        let entry: Result<(Int, String), URLError>? = lock.withLock {
            counts[key, default: 0] += 1
            guard var queue = routes[key], !queue.isEmpty else { return nil }
            let first = queue.count > 1 ? queue.removeFirst() : queue[0]
            routes[key] = queue
            return first
        }
        guard let entry, let url = request.url else { throw URLError(.cannotConnectToHost) }
        let (status, body) = try entry.get()
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
@Suite struct AccountResilienceTests {
    private func signedInAccount(http: FlakyServer) async throws -> IOSAccount {
        let keys = MemorySecretStore()
        let session = Session(
            token: "tok", user: AccountUser(id: "u1", email: "anna@example.com", name: nil, githubLogin: nil),
            device: DeviceRef(id: "phone", approved: false))
        try keys.save(try JSONEncoder().encode(session), account: AccountClient.sessionAccount)
        return IOSAccount(
            keys: keys, identities: DeviceIdentityStore(secrets: MemorySecretStore()),
            sink: AccountAccessSink(
                secrets: MemorySecretStore(),
                file: FileManager.default.temporaryDirectory.appending(path: "res-\(UUID().uuidString)/a.json")),
            noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()), http: http, deviceName: "iPhone",
            defaults: UserDefaults(suiteName: "res-\(UUID().uuidString)")!, pollInterval: .seconds(60),
            retryDelay: .zero)
    }

    private let notApproved =
        #"{"ok":true,"user":{"id":"u1","email":"anna@example.com"},"device":{"id":"phone","approved":false},"devices":[]}"#

    @Test func aConnectionDroppedOnceDuringTheAccountReadIsRetriedAndShowsNoError() async throws {
        let http = FlakyServer()
        http.script("GET /me", [.failure(URLError(.networkConnectionLost)), .success((200, notApproved))])
        let account = try await signedInAccount(http: http)
        await account.start()
        #expect(account.errorText == nil)
        #expect(http.count("GET /me") == 2)
        if case .waitingForApproval = account.stage {} else { Issue.record("stage is \(account.stage)") }
        account.cancelGitHub()
    }

    @Test func aReadThatKeepsFailingStopsTheSpinnerAndShowsTheRetryWithTheCode() async throws {
        let http = FlakyServer()
        http.script("GET /me", [.failure(URLError(.networkConnectionLost))])
        let account = try await signedInAccount(http: http)
        await account.start()
        #expect(account.stage == .loading)
        #expect(account.refreshing == 0)
        #expect(account.errorText == PhoneAccountMessages.text(for: AccountError.network("x")))
        #expect(account.errorDetails == "network NSURLErrorDomain -1005")
        #expect(AccountLoadingPresentation.of(refreshing: account.refreshing > 0, hasError: account.errorText != nil) == .retry)
    }

    @Test func theSpinnerAndTheErrorNeverShowTogether() {
        #expect(AccountLoadingPresentation.of(refreshing: true, hasError: true) == .checking)
        #expect(AccountLoadingPresentation.of(refreshing: true, hasError: false) == .checking)
        #expect(AccountLoadingPresentation.of(refreshing: false, hasError: true) == .retry)
    }

    @Test func aRetryClearsTheOldErrorWhileItRuns() async throws {
        let http = FlakyServer()
        http.script("GET /me", [.failure(URLError(.networkConnectionLost))])
        let account = try await signedInAccount(http: http)
        await account.start()
        #expect(account.errorText != nil)
        http.script("GET /me", [.success((200, notApproved))])
        await account.start()
        #expect(account.errorText == nil && account.errorDetails == nil)
        account.cancelGitHub()
    }

    @Test func aKeychainFailureIsNotReportedAsNoConnection() {
        let network = PhoneAccountMessages.text(for: AccountError.network("x"))
        let keychain = PhoneAccountMessages.text(for: SecretStoreError.keychain(-34018))
        let server = PhoneAccountMessages.text(for: AccountError.api(code: "http_502", status: 502))
        #expect(Set([network, keychain, server]).count == 3)
        #expect(PhoneAccountMessages.details(for: SecretStoreError.keychain(-34018)) == "keychain -34018")
        #expect(PhoneAccountMessages.details(for: AccountError.api(code: "http_502", status: 502)) == "api http_502 502")
    }

    @Test func verifyAfterALostAnswerThenSpentCodeAsksForANewCode() async throws {
        let http = FlakyServer()
        http.script("POST /auth/challenge", [.success((200, #"{"ok":true,"nonce":"n","expires_in":300}"#))])
        http.script(
            "POST /auth/email/verify",
            [.failure(URLError(.networkConnectionLost)), .success((401, #"{"ok":false,"error":"code_invalid"}"#))])
        let account = try await signedInAccount(http: http)
        let client = try await account.prepare()
        do {
            _ = try await client.emailVerify(email: "a@b.co", code: "123456")
            Issue.record("expected an error")
        } catch let error as AccountError {
            #expect(PhoneAccountMessages.text(for: error) == PhoneAccountMessages.apiText(AccountClient.verifyUnconfirmed))
            #expect(PhoneAccountMessages.text(for: error) != PhoneAccountMessages.text(for: AccountError.network("x")))
        }
    }

    @Test func theEmailScreenShowsNoErrorWhileItChecksTheCode() async throws {
        let service = StallingService()
        let model = PhoneEmailSignIn(service: service)
        model.email = "a@b.co"
        await model.sendCode()
        service.failVerify = true
        model.code = "123456"
        await model.verify()
        #expect(model.errorText != nil && model.isBusy == false)
        service.failVerify = false
        service.onVerify = { #expect(model.errorText == nil && model.isBusy) }
        model.code = "123456"
        await model.verify()
        #expect(model.signedIn != nil)
    }
}

private final class StallingService: PhoneSignInService, @unchecked Sendable {
    var failVerify = false
    var onVerify: (@MainActor () -> Void)?
    func githubStart() async throws -> GitHubFlow { throw AccountError.badResponse }
    func githubPoll(flowID: String) async throws -> PollResult { .pending }
    func emailStart(email: String) async throws {}
    func emailVerify(email: String, code: String) async throws -> Session {
        if failVerify { throw AccountError.network("NSURLErrorDomain -1005") }
        await onVerify?()
        return Session(
            token: "t", user: AccountUser(id: "u1", email: "a@b.co", name: nil, githubLogin: nil),
            device: DeviceRef(id: "d1", approved: true))
    }
}
