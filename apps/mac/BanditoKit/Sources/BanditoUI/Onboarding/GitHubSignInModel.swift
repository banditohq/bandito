import BanditoKit
import Foundation
import Observation

/// Where the GitHub device flow stands. `waiting` carries the code the person enters on GitHub.
enum GitHubSignInState: Equatable, Sendable {
    case idle
    case connecting
    case waiting(GitHubFlow)
    case expired
    case denied
    case failed(UserFacingMessage)
    case signedIn(Session)
}

/// The one page the code is entered on. The address from the server response is never opened.
enum GitHubDevicePage {
    static let url = URL(string: "https://github.com/login/device")!
}

/// The flow itself, without the model: start, wait, poll until a final state. It holds no reference to the
/// screen, so a Task that runs it never keeps the model alive. Every state change goes to `report`.
struct GitHubFlowRunner: Sendable {
    /// Transient errors allowed in a row before the flow fails.
    static let maxTransientErrors = 5
    /// `slow_down` never shortens the wait below the previous interval plus this.
    static let slowDownStep = 5

    let service: SignInService
    let sleep: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> Date

    func execute(report: @Sendable (GitHubSignInState) async -> Void) async {
        await report(.connecting)
        let flow: GitHubFlow
        do {
            flow = try await service.githubStart()
        } catch {
            await report(.failed(SignInMessages.text(for: error)))
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
            // The code lives for `expiresIn` seconds from the start; after that there is nothing left to poll.
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
                    await report(.failed(SignInMessages.text(for: error)))
                    return
                }
            } catch {
                await report(.failed(SignInMessages.text(for: error)))
                return
            }
        }
    }

    /// Errors a later poll can get past: the server or GitHub was briefly unreachable.
    /// A rejected device proof is not transient: the same device would fail again.
    static func isTransient(_ error: AccountError) -> Bool {
        switch error {
        case .api(let code, _):
            return code == "github_unavailable"
        case .network:
            return true
        default:
            return false
        }
    }
}

/// The GitHub sign-in on screen. The code is copied and the page opened only when the person asks ("Copy and open");
/// nothing goes to the pasteboard or the browser by itself.
@MainActor
@Observable
final class GitHubSignInModel {
    /// Written by the flow; internal so tests can put the model into a state directly.
    var state: GitHubSignInState = .idle

    @ObservationIgnored private let runner: GitHubFlowRunner
    @ObservationIgnored private let copyToPasteboard: (String) -> Void
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private var flowTask: Task<Void, Never>?

    init(
        service: SignInService,
        copyToPasteboard: @escaping (String) -> Void = SystemActions.copy,
        openURL: @escaping (URL) -> Void = SystemActions.open,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = GitHubFlowRunner(service: service, sleep: sleep, now: now)
        self.copyToPasteboard = copyToPasteboard
        self.openURL = openURL
    }

    /// Button action: runs a flow in the background. A flow already running is cancelled first.
    /// The Task holds the model weakly, so leaving the screen does not keep the flow's state alive.
    func start() {
        flowTask?.cancel()
        let runner = runner
        flowTask = Task { [weak self] in
            await runner.execute { state in
                await MainActor.run { self?.state = state }
            }
        }
    }

    /// Stops waiting, for example when the screen or the sheet goes away.
    func cancel() {
        flowTask?.cancel()
        flowTask = nil
        state = .idle
    }

    /// The button "Copy and open": the code goes to the pasteboard, the GitHub device page opens.
    func copyAndOpen() {
        guard case .waiting(let flow) = state else { return }
        copyToPasteboard(flow.userCode)
        openURL(GitHubDevicePage.url)
    }

    /// One whole flow, awaited. Used by tests; the screen uses `start()`.
    func run() async {
        await runner.execute { [weak self] state in
            await MainActor.run { self?.state = state }
        }
    }
}
