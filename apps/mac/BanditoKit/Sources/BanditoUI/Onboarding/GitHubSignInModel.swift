import BanditoKit
import Foundation
import Observation

/// Where the GitHub device flow stands. `waiting` carries the code the person enters on GitHub.
enum GitHubSignInState: Equatable {
    case idle
    case connecting
    case waiting(GitHubFlow)
    case expired
    case denied
    case failed(String)
    case signedIn(Session)
}

/// Runs one GitHub device flow: start, show the code (copied and the page opened), poll until the flow ends.
/// Pauses and the system calls are injected, so the tests run the whole flow without waiting or a browser.
@MainActor
@Observable
final class GitHubSignInModel {
    private(set) var state: GitHubSignInState = .idle

    @ObservationIgnored private let service: SignInService
    @ObservationIgnored private let copyToPasteboard: (String) -> Void
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var flowTask: Task<Void, Never>?

    init(
        service: SignInService,
        copyToPasteboard: @escaping (String) -> Void = SystemActions.copy,
        openURL: @escaping (URL) -> Void = SystemActions.open,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.copyToPasteboard = copyToPasteboard
        self.openURL = openURL
        self.sleep = sleep
    }

    /// Button action: runs a flow in the background. A flow already running is cancelled first.
    func start() {
        flowTask?.cancel()
        flowTask = Task { await run() }
    }

    /// Stops waiting, for example when the sheet is closed.
    func cancel() {
        flowTask?.cancel()
        flowTask = nil
        state = .idle
    }

    /// One whole flow. Returns when the state is final (signed in, expired, denied, failed) or the flow was cancelled.
    func run() async {
        state = .connecting
        let flow: GitHubFlow
        do {
            flow = try await service.githubStart()
        } catch {
            state = .failed(SignInMessages.text(for: error))
            return
        }
        state = .waiting(flow)
        copyToPasteboard(flow.userCode)
        openURL(flow.verificationURI)

        var interval = flow.interval
        while !Task.isCancelled {
            do {
                try await sleep(.seconds(interval))
            } catch {
                return
            }
            if Task.isCancelled { return }
            do {
                switch try await service.githubPoll(flowID: flow.flowID) {
                case .pending:
                    continue
                case .slowDown(let requested):
                    // GitHub asked for a longer wait; never shorter than the last one plus five seconds.
                    interval = max(requested, interval + 5)
                case .signedIn(let session):
                    state = .signedIn(session)
                    return
                case .expired:
                    state = .expired
                    return
                case .denied:
                    state = .denied
                    return
                }
            } catch let error as AccountError where Self.isTransient(error) {
                continue
            } catch {
                state = .failed(SignInMessages.text(for: error))
                return
            }
        }
    }

    /// Errors that a later poll can get past: the server or GitHub was briefly unreachable, or the device proof expired.
    static func isTransient(_ error: AccountError) -> Bool {
        switch error {
        case .api(let code, _):
            return code == "github_unavailable" || code == "bad_device_proof"
        case .network:
            return true
        default:
            return false
        }
    }
}
