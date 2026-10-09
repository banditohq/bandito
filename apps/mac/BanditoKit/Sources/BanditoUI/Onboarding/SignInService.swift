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

/// The account client the app uses. The device keys come from the one `DeviceIdentityStore` of the app;
/// the session is kept in the Keychain under its own service.
public enum AccountEnvironment {
    public static func live() async throws -> AccountClient {
        let identity = try await DeviceIdentityStore.shared.load()
        return try AccountClient(
            identity: identity, sessions: KeychainStore(service: "dev.bandito.account"))
    }
}
