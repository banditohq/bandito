import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// What the sign-in screens need from the account service. `AccountClient` conforms; tests use a scripted fake.
protocol PhoneSignInService: Sendable {
    func githubStart() async throws -> GitHubFlow
    func githubPoll(flowID: String) async throws -> PollResult
    func emailStart(email: String) async throws
    func emailVerify(email: String, code: String) async throws -> Session
}

extension AccountClient: PhoneSignInService {}

// MARK: - GitHub

/// Where the GitHub device flow stands. `waiting` carries the code the person enters on GitHub.
enum GitHubSignInState: Equatable, Sendable {
    case idle
    case connecting
    case waiting(GitHubFlow)
    case expired
    case denied
    case failed(String)
    case signedIn(Session)
}

/// The one page the code is entered on. The address from the server response is never opened.
enum GitHubDevicePage {
    static let url = URL(string: "https://github.com/login/device")!
}

/// The flow without the screen: start, wait, poll until a final state. Every state change goes to `report`.
struct GitHubFlowRunner: Sendable {
    /// Transient errors allowed in a row before the flow fails.
    static let maxTransientErrors = 5
    /// `slow_down` never shortens the wait below the previous interval plus this.
    static let slowDownStep = 5

    let service: PhoneSignInService
    let sleep: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> Date

    func execute(report: @Sendable (GitHubSignInState) async -> Void) async {
        await report(.connecting)
        let flow: GitHubFlow
        do {
            flow = try await service.githubStart()
        } catch {
            await report(.failed(PhoneAccountMessages.text(for: error)))
            return
        }
        await report(.waiting(flow))

        let deadline = now().addingTimeInterval(TimeInterval(flow.expiresIn))
        var interval = flow.interval
        var transientErrors = 0
        while !Task.isCancelled {
            do {
                try await sleep(.seconds(interval))
            } catch {
                return
            }
            if Task.isCancelled { return }
            if now() >= deadline {
                await report(.expired)
                return
            }
            do {
                switch try await service.githubPoll(flowID: flow.flowID) {
                case .pending:
                    transientErrors = 0
                case .slowDown(let requested):
                    transientErrors = 0
                    interval = max(requested, interval + Self.slowDownStep)
                case .signedIn(let session):
                    await report(.signedIn(session))
                    return
                case .expired:
                    await report(.expired)
                    return
                case .denied:
                    await report(.denied)
                    return
                }
            } catch let error as AccountError where Self.isTransient(error) {
                transientErrors += 1
                if transientErrors >= Self.maxTransientErrors {
                    await report(.failed(PhoneAccountMessages.text(for: error)))
                    return
                }
            } catch {
                await report(.failed(PhoneAccountMessages.text(for: error)))
                return
            }
        }
    }

    /// Errors a later poll can get past: the server or GitHub was briefly unreachable.
    static func isTransient(_ error: AccountError) -> Bool {
        switch error {
        case .api(let code, _): return code == "github_unavailable"
        case .network: return true
        default: return false
        }
    }
}

/// The GitHub sign-in on screen. The code is copied and the page opened only when the person asks.
@MainActor
@Observable
final class PhoneGitHubSignIn {
    private(set) var state: GitHubSignInState = .idle

    @ObservationIgnored private let runner: GitHubFlowRunner
    @ObservationIgnored private var flowTask: Task<Void, Never>?

    init(
        service: PhoneSignInService,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        runner = GitHubFlowRunner(service: service, sleep: sleep, now: now)
    }

    /// Runs a flow in the background; one already running is cancelled first. The Task holds the model weakly.
    func start() {
        flowTask?.cancel()
        let runner = runner
        flowTask = Task { [weak self] in
            await runner.execute { state in
                await MainActor.run { self?.state = state }
            }
        }
    }

    func cancel() {
        flowTask?.cancel()
        flowTask = nil
        state = .idle
    }

    /// A signed-in state is consumed once by the owner of this model.
    func finish() {
        flowTask = nil
        state = .idle
    }

    /// One whole flow, awaited. Used by tests.
    func run() async {
        await runner.execute { [weak self] state in
            await MainActor.run { self?.state = state }
        }
    }
}

// MARK: - Email

/// The wait before a new email code can be asked for. The server allows a few codes an hour, so the app waits a minute.
struct ResendCooldown: Equatable, Sendable {
    static let seconds = 60

    private(set) var sentAt: Date?

    mutating func markSent(at date: Date) { sentAt = date }

    /// Whole seconds still to wait, 0 when a new code may be asked for.
    func remaining(now: Date) -> Int {
        guard let sentAt else { return 0 }
        return max(0, Int((Double(Self.seconds) - now.timeIntervalSince(sentAt)).rounded(.up)))
    }
}

/// A light check before sending a code: one "@", something before it, a dot in the domain, no spaces.
enum EmailAddressCheck {
    static func isPlausible(_ raw: String) -> Bool {
        let email = raw.trimmingCharacters(in: .whitespaces)
        guard !email.contains(where: \.isWhitespace), let at = email.firstIndex(of: "@") else { return false }
        let local = email[..<at]
        let domain = email[email.index(after: at)...]
        return !local.isEmpty && !domain.isEmpty && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}

/// Sign-in by email code: ask for a code, then type the six digits. A complete code is checked at once.
@MainActor
@Observable
final class PhoneEmailSignIn {
    enum Phase: Equatable {
        case address
        case code
    }

    var email = ""
    /// Bound to the code field; digits only, at most six.
    var code = "" {
        didSet {
            let digits = String(code.filter { $0.isASCII && $0.isNumber }.prefix(6))
            if digits != code { code = digits }
        }
    }
    private(set) var phase: Phase = .address
    private(set) var errorText: String?
    private(set) var isBusy = false
    private(set) var signedIn: Session?
    private(set) var cooldown = ResendCooldown()

    @ObservationIgnored private let service: PhoneSignInService

    init(service: PhoneSignInService) {
        self.service = service
    }

    func sendCode(now: Date = Date()) async {
        guard !isBusy else { return }
        let address = email.trimmingCharacters(in: .whitespaces)
        guard EmailAddressCheck.isPlausible(address) else {
            errorText = L10n.Onboarding.Account.invalidEmail
            return
        }
        isBusy = true
        errorText = nil
        defer { isBusy = false }
        do {
            try await service.emailStart(email: address)
            email = address
            phase = .code
            code = ""
            cooldown.markSent(at: now)
        } catch {
            errorText = PhoneAccountMessages.text(for: error)
        }
    }

    func resend(now: Date = Date()) async {
        guard cooldown.remaining(now: now) == 0 else { return }
        await sendCode(now: now)
    }

    /// Checks the code once it has six digits. A wrong code clears the field so the person can try again.
    func verify() async {
        guard phase == .code, !isBusy, signedIn == nil, code.count == 6 else { return }
        isBusy = true
        errorText = nil
        defer { isBusy = false }
        do {
            signedIn = try await service.emailVerify(email: email, code: code)
        } catch {
            code = ""
            errorText = PhoneAccountMessages.text(for: error)
        }
    }

    func changeEmail() {
        phase = .address
        code = ""
        errorText = nil
    }

    func finish() {
        signedIn = nil
        phase = .address
        code = ""
        errorText = nil
    }
}
