import BanditoKit
import BanditoL10n
import Foundation

/// The rules of the iPhone block on a server's settings page and of the pairing sheet: what each choice says, when a
/// phone can be connected, and what the sheet shows for the daemon's `pair.create` reply. Views stay thin.
enum PhoneAccessRules {
    /// The UserDefaults key of the "iPhone app (beta)" switch in General. Off by default.
    static let betaStorageKey = "iphoneBeta.enabled"

    /// Whether this build is a debug build (QA), which always shows the iPhone block.
    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Whether the iPhone block shows on a server's settings page. The iPhone app is in closed testing, and a switch that
    /// opens the server to an app nobody can install only adds risk, so release builds hide the block until the beta
    /// switch in General is on. A server whose phone access is already on (not Off) always shows it, so whoever turned
    /// it on can turn it off again. Debug builds (QA) show it.
    static func showsIPhoneBlock(
        betaEnabled: Bool, serverMode: PhoneAccessMode?, debugBuild: Bool = PhoneAccessRules.isDebugBuild
    ) -> Bool {
        debugBuild || betaEnabled || (serverMode ?? .off) != .off
    }

    /// The three choices of the switch, in display order.
    static var options: [(PhoneAccessMode, String)] {
        [
            (.off, L10n.ServerSettings.Phone.Mode.off),
            (.tailscale, L10n.ServerSettings.Phone.Mode.tailscale),
            (.lan, L10n.ServerSettings.Phone.Mode.lan),
        ]
    }

    /// What the chosen mode opens up, and what it needs, under the switch.
    static func risk(for mode: PhoneAccessMode) -> String {
        switch mode {
        case .off: L10n.ServerSettings.Phone.Risk.off
        case .tailscale: L10n.ServerSettings.Phone.Risk.tailscale
        case .lan: L10n.ServerSettings.Phone.Risk.lan
        }
    }

    /// The local network opens the port to every device on it: its text is drawn as a warning.
    static func isWarning(_ mode: PhoneAccessMode) -> Bool { mode == .lan }

    /// What the status line under the switch says.
    enum Line: Equatable {
        /// Access is off: no line.
        case none
        /// The listener is up on these addresses.
        case listening(String)
        /// The mode is on but nothing listens, and the daemon gave no reason (it retries by itself).
        case notListening
        /// The daemon says why it could not listen (a short English sentence from the daemon).
        case failed(String)
    }

    static func line(mode: PhoneAccessMode, status: PhoneAccessStatus?) -> Line {
        guard mode != .off else { return .none }
        if let error = status?.error, !error.isEmpty { return .failed(error) }
        if let listening = status?.listening, !listening.isEmpty { return .listening(listening.joined(separator: ", ")) }
        return .notListening
    }

    /// Whether "Connect iPhone" can make a link now: access is on and the listener is up.
    static func canConnect(mode: PhoneAccessMode, status: PhoneAccessStatus?, cloudConnected: Bool = false) -> Bool {
        if cloudConnected { return true }
        guard mode != .off, let status else { return false }
        return !status.listening.isEmpty
    }

    /// What the pairing sheet shows for a `pair.create` reply.
    enum PairState: Equatable {
        /// The link passed the check: draw its QR code, the code, and the addresses. `viaCloud` is a link that names
        /// Bandito Relay (`hosts` may be empty then).
        case ready(link: String, code: String, hosts: [String], expiresInMinutes: Int, viaCloud: Bool)
        /// The code ran out of time: nothing of it stays on the screen.
        case expired
        /// The daemon gave no link: phone access is off or not listening.
        case notListening
        /// The link is of a version this app does not know.
        case updateApp
        /// The link did not pass the check: no QR code is drawn.
        case invalid
    }

    /// How long the code is shown: its lifetime, less a moment so a code that is about to run out is not read off the screen.
    static func shownFor(_ reply: PairCode) -> Duration {
        .milliseconds(max(0, reply.expiresInMs - 2_000))
    }

    static func pairState(for reply: PairCode) -> PairState {
        guard let link = reply.link, !link.isEmpty else { return .notListening }
        do {
            let parsed = try PhonePairLink.parse(link)
            return .ready(
                link: link, code: reply.code, hosts: parsed.hosts,
                expiresInMinutes: max(1, Int(reply.expiresInMs / 60_000)), viaCloud: parsed.relay != nil)
        } catch PhonePairLink.Problem.unsupportedVersion {
            return .updateApp
        } catch {
            return .invalid
        }
    }
}
