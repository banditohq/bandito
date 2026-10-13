import BanditoKit
import BanditoL10n
import Foundation

/// The rules of the «Через облако Bandito» block on a server's iPhone settings and of the Tailscale helper under the
/// switch: what the block says in each state, and when the helper shows. Views stay thin.
enum CloudAccessRules {
    /// What the status line of the block says.
    enum Status: Equatable {
        case off
        case enabling, connecting, disabling
        case connected
        /// On, but the server has not reached the relay (yet). `reason` is the daemon's English sentence, if any.
        case waiting(reason: String?)
        case signIn
        case unsupported
        /// The account has 10 servers in the cloud already.
        case tooMany
        case failed(UserFacingMessage)
    }

    static func status(phase: RelayController.Phase, relay: RelayStatus?, problem: RelayController.Problem?) -> Status {
        switch phase {
        case .enabling: return .enabling
        case .connecting: return .connecting
        case .disabling: return .disabling
        case .idle: break
        }
        if let problem {
            switch problem {
            case .needsSignIn: return .signIn
            case .unsupported: return .unsupported
            case .notConnected(let reason): return .waiting(reason: reason)
            case .account(let error):
                if case AccountError.api(let code, _) = error, code == "too_many" { return .tooMany }
                return .failed(SignInMessages.text(for: error))
            case .daemon(let error):
                return .failed(UserFacingError.message(for: error))
            }
        }
        guard let relay, relay.enabled else { return .off }
        return relay.connected ? .connected : .waiting(reason: relay.lastError)
    }

    /// The switch shows on while the cloud is on or being turned on, and off while it is being turned off.
    static func switchIsOn(phase: RelayController.Phase, relay: RelayStatus?, problem: RelayController.Problem?) -> Bool {
        switch phase {
        case .enabling, .connecting: return true
        case .disabling: return false
        case .idle:
            // A failed try leaves the switch where it was: off, unless the server is registered already.
            return relay?.enabled == true
        }
    }

    /// The Tailscale helper replaces the red error when the mode is on, nothing listens, and the daemon says it found no
    /// Tailscale address.
    static func showsTailscaleHelper(mode: PhoneAccessMode, status: PhoneAccessStatus?) -> Bool {
        guard mode == .tailscale, let status, status.listening.isEmpty else { return false }
        return status.error?.localizedCaseInsensitiveContains("tailscale") == true
    }

    /// How to install Tailscale on the server: a command to run there, or the app to download (macOS).
    enum Install: Equatable {
        case command(String)
        case app(URL)
    }

    static func install(os: String?) -> Install {
        if os?.lowercased() == "macos" || os?.lowercased() == "darwin", let url = URL(string: "https://tailscale.com/download/mac") {
            return .app(url)
        }
        return .command("curl -fsSL https://tailscale.com/install.sh | sh")
    }

    /// Prints the sign-in link on the server.
    static let loginCommand = "sudo tailscale up"
}

/// Where a person without the iPhone app gets it.
enum IPhoneApp {
    /// The TestFlight invitation of the closed beta.
    static let testFlight = URL(string: "https://bandito.dev")!
}
