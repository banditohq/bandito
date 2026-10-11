import BanditoDesign
@testable import BanditoKit
import BanditoL10n
import SwiftUI
import Testing

@testable import BanditoUI

/// A sign-in service that is never reached: the sheets are shown in a state set by hand.
private struct UnreachableSignInService: SignInService {
    func githubStart() async throws -> GitHubFlow { throw URLError(.notConnectedToInternet) }
    func githubPoll(flowID: String) async throws -> PollResult { throw URLError(.notConnectedToInternet) }
    func emailStart(email: String) async throws { throw URLError(.notConnectedToInternet) }
    func emailVerify(email: String, code: String) async throws -> Session { throw URLError(.notConnectedToInternet) }
}

/// The sign-in sheets (service in the browser, service with a code, GitHub), each in the states with the longest text.
extension LayoutAuditSnapshots {
    private static let longFailure = UserFacingMessage(
        text: "The service did not accept the sign-in. Check that the account has access to the workspace and try again.",
        technical: "invalid_grant: the authorization code was already used or has expired (request 0f3a9c1e)",
        canRetry: true)

    private static func oauth(_ phase: OAuthSignIn.Phase, defaults: UserDefaults) -> AnyView {
        let model = OAuthSignIn(defaults: defaults)
        model.phase = phase
        return AnyView(OAuthSignInSheet(oauth: model))
    }

    private static func device(_ phase: DeviceSignIn.Phase) -> AnyView {
        let model = DeviceSignIn()
        model.phase = phase
        return AnyView(DeviceSignInSheet(device: model))
    }

    private static func github(_ state: GitHubSignInState) -> AnyView {
        let model = GitHubSignInModel(service: UnreachableSignInService())
        model.state = state
        return AnyView(GitHubSignInSheet(model: model, close: {}))
    }

    /// The "Add a server" flow in one phase (the content of `AddServerSheet`: 680 pt sheet, 28 pt padding).
    private static func addServer(_ prepare: @escaping @MainActor (FirstServerModel) -> Void) -> AnyView {
        let model = FirstServerModel()
        prepare(model)
        return AnyView(FirstServerStep(onFinished: {}, model: model).padding(28).frame(width: 680, alignment: .topLeading))
    }

    private static let hostKey = HostKeyPreview(
        keyType: "ed25519", fingerprint: "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
        scanOutput: "bandito-production-frankfurt.example.internal ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBandito",
        knownHostsLines: [])

    static let serverFlowSheets: [AuditCase] = [
        AuditCase(name: "flow-server-choose", width: 680, selfSized: true) { _ in addServer { _ in } },
        AuditCase(name: "flow-server-own", width: 680, selfSized: true) { _ in
            addServer {
                $0.choose(.ownServer)
                $0.address = "deploy-user@bandito-production-frankfurt.example.internal:2222"
            }
        },
        AuditCase(name: "flow-server-installing", width: 680, selfSized: true) { _ in
            addServer {
                $0.choose(.ownServer)
                $0.phase = .installing
            }
        },
        AuditCase(name: "flow-server-failed", width: 680, selfSized: true) { _ in
            addServer {
                $0.choose(.ownServer)
                $0.checklist.failLast(
                    .step(
                        "Install the Bandito server",
                        detail: "curl: (7) Failed to connect to github.com port 443 after 75003 ms: Couldn't connect to server"))
                $0.phase = .failed
            }
        },
        AuditCase(name: "flow-server-host-key", width: 680, selfSized: true) { _ in
            addServer {
                $0.choose(.ownServer)
                $0.address = "deploy-user@bandito-production-frankfurt.example.internal"
                $0.phase = .reviewingHost(hostKey)
            }
        },
    ]

    static let flowSheets: [AuditCase] = serverFlowSheets + [
        AuditCase(name: "sheet-oauth-waiting", width: 420, selfSized: true) { env in
            oauth(.waiting(name: "Google Workspace Admin"), defaults: env.defaults)
        },
        AuditCase(name: "sheet-oauth-failed", width: 420, selfSized: true) { env in
            oauth(.failed(name: "Google Workspace Admin", message: longFailure, canRetry: true), defaults: env.defaults)
        },
        AuditCase(name: "sheet-device-waiting", width: 420, selfSized: true) { _ in
            device(
                .waiting(
                    name: "GitHub Copilot for Business", code: "ABCD-1234",
                    page: DevicePage("https://github.com/login/device")!,
                    expiresAt: Date().addingTimeInterval(900)))
        },
        AuditCase(name: "sheet-device-failed", width: 420, selfSized: true) { _ in
            device(.failed(name: "GitHub Copilot for Business", message: longFailure, canRetry: true))
        },
        AuditCase(name: "sheet-github-waiting", width: 420, selfSized: true) { _ in
            github(
                .waiting(
                    GitHubFlow(
                        flowID: "f", userCode: "ABCD-1234", verificationURI: URL(string: "https://github.com/login/device")!,
                        interval: 5, expiresIn: 900)))
        },
        AuditCase(name: "sheet-github-failed", width: 420, selfSized: true) { _ in
            github(.failed(longFailure))
        },
        AuditCase(name: "sheet-github-expired", width: 420, selfSized: true) { _ in github(.expired) },
    ]
}
