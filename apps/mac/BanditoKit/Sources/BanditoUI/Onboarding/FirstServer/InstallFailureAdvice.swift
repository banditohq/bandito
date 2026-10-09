import BanditoKit

/// One thing the person can do after an install failed. The view turns it into a localized line.
enum InstallNextStep: Equatable {
    /// The server does not accept this Mac's key: check the login in Terminal, then add the key once.
    case checkTerminalLogin
    /// The name does not resolve: check the address for typos.
    case checkServerAddress
    /// No answer or no route: check the address, and VPN or Tailscale on this Mac.
    case checkServerReachable
    /// Nothing listens on that port: check the SSH port.
    case checkSSHPort
    /// The release could not be fetched: check the internet, VPN or proxy to github.com.
    case checkGitHubAccess
    /// The release did not pass its check, or is still being published: nothing was installed, try again later.
    case retryLater
    /// The system is not one Bandito covers. `uname` is what the server reported.
    case checkSystemSupport(uname: String)
    /// The start or the pairing failed: the journal has the last lines of the daemon's log.
    case readLog
    /// A new host: compare the fingerprint, then trust it only if it is the server's.
    case reviewFingerprint
    /// The key changed: someone may be in the middle. Check the server; nothing is trusted.
    case checkServerKey
    /// Nothing more to suggest. The reason says it.
    case none
}

/// What an install failure shows under its reason: the next step, and whether the installer's own text goes in the
/// details. The text of the reason itself comes from `FirstServerStep.failureText`.
enum InstallFailureAdvice {
    /// The installer's own text (`InstallError.errorDescription`) is shown under "Details" for these failures, since the
    /// reason above does not say what went wrong.
    static func showsDetails(_ failure: InstallError) -> Bool {
        switch failure {
        case .sshFailed(.other), .step, .io, .badResponse, .downloadFailed, .serviceFailed, .pairingFailed:
            return true
        default:
            return false
        }
    }

    static func nextStep(for failure: InstallError) -> InstallNextStep {
        switch failure {
        case .sshFailed(let reason):
            switch reason {
            case .keyNotAccepted: return .checkTerminalLogin
            case .unknownHost: return .checkServerAddress
            case .timedOut, .noRoute: return .checkServerReachable
            case .refused: return .checkSSHPort
            case .hostKeyUnknown: return .reviewFingerprint
            case .hostKeyChanged: return .checkServerKey
            case .other: return .none
            }
        case .unsupportedPlatform(let uname):
            return .checkSystemSupport(uname: uname)
        case .downloadFailed:
            return .checkGitHubAccess
        case .releaseCheckFailed, .releaseStillPublishing:
            return .retryLater
        case .localDaemonNotStarted, .serviceFailed, .pairingFailed, .badResponse, .step:
            return .readLog
        default:
            return .none
        }
    }
}
