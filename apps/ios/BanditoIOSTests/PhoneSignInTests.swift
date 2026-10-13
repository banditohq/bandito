import BanditoKit
import Foundation
import Testing

@testable import Bandito

/// A sign-in service that answers from a script. A poll takes the next answer, and repeats the last.
private final class ScriptedSignIn: PhoneSignInService, @unchecked Sendable {
    // @unchecked: `polls`, `startCalls` and the counters are guarded by `lock`.
    private let lock = NSLock()
    var flow = GitHubFlow(
        flowID: "f1", userCode: "WDJBMJHT", verificationURI: URL(string: "https://github.com/login/device")!,
        interval: 5, expiresIn: 900)
    var startError: Error?
    var polls: [Result<PollResult, Error>] = []
    var verify: Result<Session, Error>?
    var emailError: Error?
    private(set) var pollCount = 0
    private(set) var emails: [String] = []

    func githubStart() async throws -> GitHubFlow {
        if let startError { throw startError }
        return flow
    }

    func githubPoll(flowID: String) async throws -> PollResult {
        let next: Result<PollResult, Error> = lock.withLock {
            pollCount += 1
            if polls.count > 1 { return polls.removeFirst() }
            return polls.first ?? .success(.pending)
        }
        return try next.get()
    }

    func emailStart(email: String) async throws {
        if let emailError { throw emailError }
        lock.withLock { emails.append(email) }
    }

    func emailVerify(email: String, code: String) async throws -> Session {
        try (verify ?? .failure(AccountError.api(code: "code_invalid", status: 400))).get()
    }
}

private let session = Session(
    token: "t", user: AccountUser(id: "u1", email: "a@b.co", name: nil, githubLogin: nil),
    device: DeviceRef(id: "d1", approved: true))

/// The recorded states of a GitHub flow.
private actor Recorder {
    private(set) var states: [GitHubSignInState] = []
    func add(_ state: GitHubSignInState) { states.append(state) }
}

@Suite struct PhoneSignInTests {
    private func run(_ service: ScriptedSignIn, now: @escaping @Sendable () -> Date = { Date() }) async -> (states: [GitHubSignInState], sleeps: [Int]) {
        let recorder = Recorder()
        let sleeps = Recorder2()
        let runner = GitHubFlowRunner(
            service: service, sleep: { duration in await sleeps.add(Int(duration.components.seconds)) }, now: now)
        await runner.execute { await recorder.add($0) }
        return (await recorder.states, await sleeps.values)
    }

    private actor Recorder2 {
        private(set) var values: [Int] = []
        func add(_ value: Int) { values.append(value) }
    }

    @Test func theGitHubFlowWaitsPollsAndSignsIn() async {
        let service = ScriptedSignIn()
        service.polls = [.success(.pending), .success(.signedIn(session))]
        let result = await run(service)
        #expect(result.states == [.connecting, .waiting(service.flow), .signedIn(session)])
        #expect(result.sleeps == [5, 5])
    }

    @Test func slowDownNeverShortensTheWait() async {
        let service = ScriptedSignIn()
        service.polls = [.success(.slowDown(interval: 5)), .success(.signedIn(session))]
        let result = await run(service)
        #expect(result.sleeps == [5, 10])
    }

    @Test func expiredAndDeniedAreFinalStates() async {
        let expired = ScriptedSignIn()
        expired.polls = [.success(.expired)]
        #expect(await run(expired).states.last == .expired)
        let denied = ScriptedSignIn()
        denied.polls = [.success(.denied)]
        #expect(await run(denied).states.last == .denied)
    }

    @Test func theFlowStopsWhenTheCodeHasExpired() async {
        let service = ScriptedSignIn()
        // The clock jumps past the lifetime of the code after the start.
        let calls = Counter()
        let result = await run(service, now: { calls.next() > 1 ? Date(timeIntervalSinceNow: 10_000) : Date() })
        #expect(result.states.last == .expired)
        #expect(service.pollCount == 0)
    }

    @Test func briefNetworkTroubleIsRiddenOutButNotForever() async {
        let flaky = ScriptedSignIn()
        flaky.polls = [.failure(AccountError.network("x")), .failure(AccountError.network("x")), .success(.signedIn(session))]
        #expect(await run(flaky).states.last == .signedIn(session))

        let dead = ScriptedSignIn()
        dead.polls = [.failure(AccountError.network("x"))]
        let states = await run(dead).states
        guard case .failed = states.last else {
            Issue.record("expected failed, got \(String(describing: states.last))")
            return
        }
        #expect(dead.pollCount == GitHubFlowRunner.maxTransientErrors)

        let refused = ScriptedSignIn()
        refused.polls = [.failure(AccountError.api(code: "bad_device_proof", status: 401))]
        guard case .failed = await run(refused).states.last else {
            Issue.record("a rejected proof is not transient")
            return
        }
        #expect(refused.pollCount == 1)
    }

    @Test func aFlowThatCannotStartFails() async {
        let service = ScriptedSignIn()
        service.startError = AccountError.api(code: "rate", status: 429)
        let states = await run(service).states
        #expect(states.first == .connecting)
        guard case .failed = states.last else {
            Issue.record("expected failed")
            return
        }
    }

    // MARK: email

    @MainActor @Test func aBadAddressIsRefusedWithoutARequest() async {
        let service = ScriptedSignIn()
        let model = PhoneEmailSignIn(service: service)
        model.email = "nope"
        await model.sendCode()
        #expect(model.phase == .address && model.errorText != nil && service.emails.isEmpty)
    }

    @MainActor @Test func theCodeFieldKeepsSixDigitsAndTheRightCodeSignsIn() async {
        let service = ScriptedSignIn()
        service.verify = .success(session)
        let model = PhoneEmailSignIn(service: service)
        model.email = " a@b.co "
        await model.sendCode(now: Date(timeIntervalSince1970: 100))
        #expect(model.phase == .code && service.emails == ["a@b.co"])
        #expect(model.cooldown.remaining(now: Date(timeIntervalSince1970: 130)) == 30)
        #expect(model.cooldown.remaining(now: Date(timeIntervalSince1970: 200)) == 0)

        model.code = "12 34-56789"
        #expect(model.code == "123456")
        await model.verify()
        #expect(model.signedIn == session)
        // Nothing is checked twice.
        service.verify = .failure(AccountError.api(code: "code_invalid", status: 400))
        await model.verify()
        #expect(model.signedIn == session)
    }

    @MainActor @Test func aWrongCodeClearsTheFieldAndShowsTheReason() async {
        let service = ScriptedSignIn()
        let model = PhoneEmailSignIn(service: service)
        model.email = "a@b.co"
        await model.sendCode()
        model.code = "000000"
        await model.verify()
        #expect(model.code.isEmpty && model.signedIn == nil && model.errorText != nil)
        // An incomplete code is not sent at all.
        model.code = "123"
        await model.verify()
        #expect(model.signedIn == nil)
    }

    @MainActor @Test func resendWaitsForTheCooldown() async {
        let service = ScriptedSignIn()
        let model = PhoneEmailSignIn(service: service)
        model.email = "a@b.co"
        let start = Date(timeIntervalSince1970: 1_000)
        await model.sendCode(now: start)
        await model.resend(now: start.addingTimeInterval(10))
        #expect(service.emails.count == 1)
        await model.resend(now: start.addingTimeInterval(61))
        #expect(service.emails.count == 2)
    }

    @Test func messagesComeFromTheAppsOwnTranslations() {
        #expect(PhoneAccountMessages.text(for: AccountError.network("x")).isEmpty == false)
        #expect(PhoneAccountMessages.text(for: AccountError.api(code: "no_such_code", status: 400)) == PhoneAccountMessages.apiText("zzz"))
        #expect(PhoneAccountMessages.text(for: DeviceIdentityError.corruptKey) == PhoneAccountMessages.text(for: SecretStoreError.keychain(-1)))
    }
}

/// A counter the `now` closures share.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
