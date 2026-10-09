import BanditoKit
import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

/// Scripted account service. Each poll pops the next scripted answer; without one the flow expires.
actor FakeSignInService: SignInService {
    private var start: Result<GitHubFlow, AccountError>
    private var polls: [Result<PollResult, AccountError>]
    private var emailStartError: AccountError?
    private var verifyResult: Result<Session, AccountError>

    private(set) var startCalls = 0
    private(set) var pollCalls = 0
    private(set) var emailStarts: [String] = []
    private(set) var verifyCalls: [(email: String, code: String)] = []

    init(
        start: Result<GitHubFlow, AccountError> = .success(FakeSignInService.flow),
        polls: [Result<PollResult, AccountError>] = [],
        emailStartError: AccountError? = nil,
        verify: Result<Session, AccountError> = .success(FakeSignInService.session)
    ) {
        self.start = start
        self.polls = polls
        self.emailStartError = emailStartError
        self.verifyResult = verify
    }

    static let flow = GitHubFlow(
        flowID: "flow-1", userCode: "WDJB-MJHT", verificationURI: URL(string: "https://github.com/login/device")!,
        interval: 5, expiresIn: 900)

    static let session = Session(
        token: "token",
        user: AccountUser(id: "user-1", email: "me@example.com", name: nil, githubLogin: "octo"),
        device: DeviceRef(id: "device-1", approved: true))

    func githubStart() async throws -> GitHubFlow {
        startCalls += 1
        return try start.get()
    }

    func githubPoll(flowID: String) async throws -> PollResult {
        pollCalls += 1
        // Out of script: the flow ends. A `pending` default would keep the poll loop running forever.
        guard !polls.isEmpty else { return .expired }
        return try polls.removeFirst().get()
    }

    func emailStart(email: String) async throws {
        emailStarts.append(email)
        if let emailStartError { throw emailStartError }
    }

    func emailVerify(email: String, code: String) async throws -> Session {
        verifyCalls.append((email, code))
        return try verifyResult.get()
    }
}

/// Records the seconds the model waited, instead of waiting.
actor SleepLog {
    private(set) var seconds: [Int] = []
    func record(_ duration: Duration) { seconds.append(Int(duration.components.seconds)) }
}

/// Collects what the model asked the system to do (copy, open).
@MainActor
final class SystemCalls {
    var copied: [String] = []
    var opened: [URL] = []
}

@MainActor
@Suite struct SignInLogicTests {
    // MARK: user code

    @Test func userCodeIsGroupedInFours() {
        #expect(UserCodeFormat.grouped("WDJB-MJHT") == "WDJB-MJHT")
        #expect(UserCodeFormat.grouped("ABCD1234") == "ABCD-1234")
        #expect(UserCodeFormat.grouped("") == "")
    }

    // MARK: six digits

    @Test func pastingAFullCodeFillsAllBoxesAndIgnoresSeparators() {
        var code = SixDigitCode()
        let complete = code.input("12 34-56", at: 0)
        #expect(code.value == "123456")
        #expect(complete)
    }

    @Test func typingOneDigitFillsOnlyItsBox() {
        var code = SixDigitCode()
        let completed = code.input("7", at: 2)
        #expect(!completed)
        #expect(code.value == "7")
        #expect(code.slots[2] == "7")
        #expect(code.slots[0] == nil)
    }

    @Test func nonDigitsAreIgnored() {
        var code = SixDigitCode()
        let completed = code.input("a", at: 0)
        #expect(!completed)
        #expect(code.value == "")
    }

    @Test func pasteStartingInTheMiddleStopsAtTheLastBox() {
        var code = SixDigitCode()
        _ = code.input("123456789", at: 3)
        #expect(code.slots == [nil, nil, nil, "1", "2", "3"])
        #expect(!code.isComplete)
    }

    @Test func clearingABoxEmptiesOnlyThatBox() {
        var code = SixDigitCode()
        _ = code.input("123456", at: 0)
        code.clear(at: 4)
        #expect(code.value == "12346")
        #expect(code.slots[4] == nil)
        #expect(code.slots[3] == "4")
        #expect(!code.isComplete)
    }

    // MARK: resend cooldown

    @Test func resendWaitsAMinuteAfterEachSend() {
        var cooldown = ResendCooldown()
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(cooldown.remaining(now: t0) == 0)
        cooldown.markSent(at: t0)
        #expect(cooldown.remaining(now: t0.addingTimeInterval(1)) == 59)
        #expect(cooldown.remaining(now: t0.addingTimeInterval(60)) == 0)
    }

    // MARK: email

    @Test func invalidEmailNeverReachesTheServer() async {
        let service = FakeSignInService()
        let model = EmailSignInModel(service: service)
        model.email = "not-an-email"
        await model.sendCode(now: Date())
        #expect(await service.emailStarts.isEmpty)
        #expect(model.errorText?.text == L10n.Onboarding.Account.invalidEmail)
        #expect(model.phase == .address)
    }

    @Test func sendingACodeMovesToCodeEntry() async {
        let service = FakeSignInService()
        let model = EmailSignInModel(service: service)
        model.email = "a@b.dev"
        await model.sendCode(now: Date())
        #expect(model.phase == .code)
        #expect(await service.emailStarts == ["a@b.dev"])
        #expect(model.errorText == nil)
    }

    @Test func typingSixDigitsSignsInOnce() async {
        let service = FakeSignInService()
        let model = EmailSignInModel(service: service)
        model.email = "a@b.dev"
        await model.sendCode(now: Date())
        for k in 0..<6 {
            await model.enter(String(k + 1), at: k)
        }
        let calls = await service.verifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.code == "123456")
        #expect(calls.first?.email == "a@b.dev")
        #expect(model.signedIn != nil)
    }

    @Test func pastingTheWholeCodeSignsInWithoutTyping() async {
        let service = FakeSignInService()
        let model = EmailSignInModel(service: service)
        model.email = "a@b.dev"
        await model.sendCode(now: Date())
        await model.enter("654321", at: 0)
        #expect(await service.verifyCalls.map(\.code) == ["654321"])
    }

    @Test func wrongCodeClearsTheBoxesAndKeepsTheCodeStep() async {
        let service = FakeSignInService(verify: .failure(.api(code: "code_invalid", status: 401)))
        let model = EmailSignInModel(service: service)
        model.email = "a@b.dev"
        await model.sendCode(now: Date())
        await model.enter("000000", at: 0)
        #expect(model.phase == .code)
        #expect(model.code.value == "")
        #expect(model.errorText?.text == L10n.Onboarding.Failure.codeInvalid)
        #expect(model.signedIn == nil)
    }

    @Test func resendIsBlockedUntilTheCooldownEnds() async {
        let service = FakeSignInService()
        let model = EmailSignInModel(service: service)
        model.email = "a@b.dev"
        let t0 = Date(timeIntervalSince1970: 5_000)
        await model.sendCode(now: t0)
        await model.resend(now: t0.addingTimeInterval(10))
        #expect(await service.emailStarts.count == 1)
        await model.resend(now: t0.addingTimeInterval(61))
        #expect(await service.emailStarts.count == 2)
    }

    @Test func clearingABoxLeavesTheOthers() async {
        let service = FakeSignInService()
        let model = EmailSignInModel(service: service)
        model.email = "a@b.dev"
        await model.sendCode(now: Date())
        await model.enter("1", at: 0)
        await model.enter("2", at: 1)
        model.clearBox(at: 0)
        #expect(model.code.slots[0] == nil)
        #expect(model.code.slots[1] == "2")
        #expect(await service.verifyCalls.isEmpty)
    }

    @Test func changingTheEmailClearsTheCode() async {
        let service = FakeSignInService()
        let model = EmailSignInModel(service: service)
        model.email = "a@b.dev"
        await model.sendCode(now: Date())
        await model.enter("12", at: 0)
        model.changeEmail()
        #expect(model.phase == .address)
        #expect(model.code.value == "")
    }

    @Test func inputThatChangesNothingDoesNotComplete() {
        var code = SixDigitCode()
        _ = code.input("123456", at: 0)
        let changed = code.input("x", at: 0)
        #expect(changed == false)
        let noBox = code.input("1", at: 9)
        #expect(noBox == false)
    }

    @Test func aSecondSendWhileTheFirstIsInFlightIsIgnored() async {
        let service = FakeSignInService()
        let model = EmailSignInModel(service: service)
        model.email = "a@b.dev"
        let now = Date()
        async let first: Void = model.sendCode(now: now)
        async let second: Void = model.sendCode(now: now)
        _ = await (first, second)
        #expect(await service.emailStarts.count == 1)
    }

    @Test func codeIsCheckedOnlyOnceAfterSignIn() async {
        let service = FakeSignInService()
        let model = EmailSignInModel(service: service)
        model.email = "a@b.dev"
        await model.sendCode(now: Date())
        await model.enter("123456", at: 0)
        await model.enter("9", at: 0)
        await model.verify()
        #expect(await service.verifyCalls.count == 1)
    }

    // MARK: GitHub device flow

    @Test func githubSignsInAfterAPendingPoll() async {
        let service = FakeSignInService(polls: [.success(.pending), .success(.signedIn(FakeSignInService.session))])
        let calls = SystemCalls()
        let sleeps = SleepLog()
        let model = GitHubSignInModel(
            service: service,
            copyToPasteboard: { calls.copied.append($0) },
            openURL: { calls.opened.append($0) },
            sleep: { await sleeps.record($0) })
        await model.run()
        #expect(model.state == .signedIn(FakeSignInService.session))
        #expect(await service.pollCalls == 2)
        #expect(await sleeps.seconds == [5, 5])
    }

    @Test func nothingIsCopiedOrOpenedWithoutTheButton() async {
        let service = FakeSignInService(polls: [.success(.signedIn(FakeSignInService.session))])
        let calls = SystemCalls()
        let model = GitHubSignInModel(
            service: service,
            copyToPasteboard: { calls.copied.append($0) },
            openURL: { calls.opened.append($0) },
            sleep: { _ in })
        await model.run()
        #expect(calls.copied.isEmpty)
        #expect(calls.opened.isEmpty)
    }

    @Test func copyAndOpenUsesTheFixedPageNotTheResponseAddress() {
        let evil = GitHubFlow(
            flowID: "flow-2", userCode: "ABCD-1234", verificationURI: URL(string: "https://phish.example/login")!,
            interval: 5, expiresIn: 900)
        let calls = SystemCalls()
        let model = GitHubSignInModel(
            service: FakeSignInService(), copyToPasteboard: { calls.copied.append($0) },
            openURL: { calls.opened.append($0) }, sleep: { _ in })
        model.state = .waiting(evil)
        model.copyAndOpen()
        #expect(calls.copied == ["ABCD-1234"])
        #expect(calls.opened == [URL(string: "https://github.com/login/device")!])
    }

    @Test func copyAndOpenDoesNothingOutsideTheWaitingState() {
        let calls = SystemCalls()
        let model = GitHubSignInModel(
            service: FakeSignInService(), copyToPasteboard: { calls.copied.append($0) },
            openURL: { calls.opened.append($0) }, sleep: { _ in })
        model.copyAndOpen()
        #expect(calls.copied.isEmpty && calls.opened.isEmpty)
    }

    @Test func aFlowPastItsDeadlineExpiresWithoutPolling() async {
        let short = GitHubFlow(
            flowID: "flow-3", userCode: "WDJB-MJHT", verificationURI: FakeSignInService.flow.verificationURI,
            interval: 5, expiresIn: 0)
        let service = FakeSignInService(start: .success(short), polls: [.success(.pending)])
        let model = GitHubSignInModel(service: service, copyToPasteboard: { _ in }, openURL: { _ in }, sleep: { _ in })
        await model.run()
        #expect(model.state == .expired)
        #expect(await service.pollCalls == 0)
    }

    @Test func slowDownWaitsLongerThanBefore() async {
        let service = FakeSignInService(polls: [.success(.slowDown(interval: 7)), .success(.signedIn(FakeSignInService.session))])
        let sleeps = SleepLog()
        let model = GitHubSignInModel(
            service: service, copyToPasteboard: { _ in }, openURL: { _ in },
            sleep: { await sleeps.record($0) })
        await model.run()
        // The server asked for 7 s, but never less than the previous interval plus five.
        #expect(await sleeps.seconds == [5, 10])
    }

    @Test func expiredFlowEndsWithAMessage() async {
        let service = FakeSignInService(polls: [.success(.expired)])
        let model = GitHubSignInModel(service: service, copyToPasteboard: { _ in }, openURL: { _ in }, sleep: { _ in })
        await model.run()
        #expect(model.state == .expired)
    }

    @Test func refusedFlowEndsWithAMessage() async {
        let service = FakeSignInService(polls: [.success(.denied)])
        let model = GitHubSignInModel(service: service, copyToPasteboard: { _ in }, openURL: { _ in }, sleep: { _ in })
        await model.run()
        #expect(model.state == .denied)
    }

    @Test func githubUnavailableKeepsPolling() async {
        let service = FakeSignInService(polls: [
            .failure(.api(code: "github_unavailable", status: 503)),
            .success(.signedIn(FakeSignInService.session)),
        ])
        let model = GitHubSignInModel(service: service, copyToPasteboard: { _ in }, openURL: { _ in }, sleep: { _ in })
        await model.run()
        #expect(model.state == .signedIn(FakeSignInService.session))
    }

    @Test func fourTransientErrorsInARowStillAllowAnotherPoll() async {
        let unavailable = Result<PollResult, AccountError>.failure(.api(code: "github_unavailable", status: 503))
        let service = FakeSignInService(polls: [unavailable, unavailable, unavailable, unavailable,
            .success(.signedIn(FakeSignInService.session))])
        let model = GitHubSignInModel(service: service, copyToPasteboard: { _ in }, openURL: { _ in }, sleep: { _ in })
        await model.run()
        #expect(model.state == .signedIn(FakeSignInService.session))
    }

    @Test func fiveTransientErrorsInARowFailTheFlow() async {
        let unavailable = Result<PollResult, AccountError>.failure(.api(code: "github_unavailable", status: 503))
        let service = FakeSignInService(polls: [unavailable, unavailable, unavailable, unavailable, unavailable,
            .success(.signedIn(FakeSignInService.session))])
        let model = GitHubSignInModel(service: service, copyToPasteboard: { _ in }, openURL: { _ in }, sleep: { _ in })
        await model.run()
        guard case .failed = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
        #expect(await service.pollCalls == 5)
    }

    @Test func aPendingPollResetsTheTransientCount() async {
        let unavailable = Result<PollResult, AccountError>.failure(.api(code: "github_unavailable", status: 503))
        var script = [unavailable, unavailable, unavailable, unavailable, .success(.pending)]
        script += [unavailable, unavailable, unavailable, unavailable, .success(.signedIn(FakeSignInService.session))]
        let service = FakeSignInService(polls: script)
        let model = GitHubSignInModel(service: service, copyToPasteboard: { _ in }, openURL: { _ in }, sleep: { _ in })
        await model.run()
        #expect(model.state == .signedIn(FakeSignInService.session))
    }

    @Test func aRejectedDeviceProofIsNotRetried() async {
        let service = FakeSignInService(polls: [.failure(.api(code: "bad_device_proof", status: 400))])
        let model = GitHubSignInModel(service: service, copyToPasteboard: { _ in }, openURL: { _ in }, sleep: { _ in })
        await model.run()
        guard case .failed = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
        #expect(await service.pollCalls == 1)
    }

    @Test func aFailedStartShowsAReadableMessage() async {
        let service = FakeSignInService(start: .failure(.api(code: "rate", status: 429)))
        let model = GitHubSignInModel(service: service, copyToPasteboard: { _ in }, openURL: { _ in }, sleep: { _ in })
        await model.run()
        #expect(model.state == .failed(UserFacingMessage(text: L10n.Onboarding.Failure.rate)))
    }

    @Test func tryAgainStartsANewFlow() async {
        let service = FakeSignInService(polls: [.success(.expired)])
        let model = GitHubSignInModel(service: service, copyToPasteboard: { _ in }, openURL: { _ in }, sleep: { _ in })
        await model.run()
        await model.run()
        #expect(await service.startCalls == 2)
    }

    // MARK: messages

    @Test func accountErrorsBecomeHumanText() {
        for code in ["rate", "code_invalid", "github_unavailable", "bad_device_proof", "expired"] {
            let text = SignInMessages.text(for: AccountError.api(code: code, status: 400)).text
            #expect(!text.isEmpty)
            #expect(text != code)
        }
    }

    @Test func otherErrorsGetAGenericMessage() {
        struct Unknown: Error {}
        // Not a sign-in error: the one mapper's generic sentence, with the description under "Подробнее".
        #expect(SignInMessages.text(for: Unknown()).text == L10n.Failure.generic)
        #expect(SignInMessages.text(for: Unknown()).technical != nil)
    }

    @Test func emailShapeIsCheckedBeforeSending() {
        #expect(EmailAddressCheck.isPlausible("a@b.dev"))
        #expect(!EmailAddressCheck.isPlausible("a@b"))
        #expect(!EmailAddressCheck.isPlausible("@b.dev"))
        #expect(!EmailAddressCheck.isPlausible("a b@c.dev"))
    }
}

@MainActor
@Suite struct SignInMessageTests {
    @Test func everyAccountCodeHasItsOwnTextNotTheKitsEnglish() {
        for code in ["invalid", "code_invalid", "rate", "session_too_old", "github_unavailable", "lastdevice-unknown"] {
            let text = SignInMessages.text(for: AccountError.api(code: code, status: 400)).text
            #expect(!text.isEmpty)
            #expect(text != code)
        }
        #expect(SignInMessages.text(for: AccountError.api(code: "rate", status: 429)).text == L10n.Onboarding.Failure.rate)
        #expect(SignInMessages.text(for: AccountError.network("offline")).text == L10n.Onboarding.Failure.network)
    }

    @Test func hostKeyFileErrorsUseTheirOwnTexts() {
        #expect(SignInMessages.text(for: SSHHostKeyError.readFailed("known_hosts")).text
            == L10n.Onboarding.Failure.hostKeyReadFailed)
        #expect(SignInMessages.text(for: SSHHostKeyError.writeFailed("known_hosts")).text
            == L10n.Onboarding.Failure.hostKeyWriteFailed)
        #expect(SignInMessages.text(for: SSHHostKeyError.keyChangedSincePreviousVisit(host: "h")).text
            == L10n.Onboarding.Failure.knownHostConflict)
        #expect(SignInMessages.text(for: SSHHostKeyError.noKey).text == L10n.Onboarding.Server.hostKeyScanFailed)
    }
}
