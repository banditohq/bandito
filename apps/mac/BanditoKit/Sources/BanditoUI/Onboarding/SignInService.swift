import BanditoKit
import Foundation

/// What the sign-in screens need from the account service. `AccountClient` conforms; tests use a scripted fake.
public protocol SignInService: Sendable {
    func githubStart() async throws -> GitHubFlow
    func githubPoll(flowID: String) async throws -> PollResult
    func emailStart(email: String) async throws
    func emailVerify(email: String, code: String) async throws -> Session
}

extension AccountClient: SignInService {}
