import BanditoL10n
import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoUI

/// The iPhone block of a server's settings page: the switch, the status line, when a phone can be connected, and what
/// the pairing sheet shows for each answer of the daemon.
@Suite struct PhoneAccessRulesTests {
    private static let fp = String(repeating: "ab", count: 32)
    private static let code = "otter-lava-mint-orbit-crane-fig"
    private static let link = PhonePairLink.make(
        code: code, fingerprint: fp, name: "Mac", hosts: ["100.64.0.1:7879", "192.168.1.5:7879"])

    private static func up(_ mode: PhoneAccessMode = .lan) -> PhoneAccessStatus {
        PhoneAccessStatus(mode: mode, listening: ["0.0.0.0:7879"])
    }

    @Test func theSwitchHasOffTailscaleAndLocalNetworkInThatOrder() {
        #expect(PhoneAccessRules.options.map(\.0) == [.off, .tailscale, .lan])
        #expect(Set(PhoneAccessRules.options.map(\.1)).count == 3)
        #expect(PhoneAccessRules.options.allSatisfy { !$0.1.isEmpty })
    }

    @Test func everyModeSaysWhatItRisksAndOnlyTheLocalNetworkIsAWarning() {
        for mode in PhoneAccessMode.allCases {
            #expect(!PhoneAccessRules.risk(for: mode).isEmpty)
        }
        #expect(PhoneAccessRules.risk(for: .tailscale) != PhoneAccessRules.risk(for: .lan))
        #expect(PhoneAccessRules.isWarning(.lan))
        #expect(!PhoneAccessRules.isWarning(.tailscale))
        #expect(!PhoneAccessRules.isWarning(.off))
    }

    @Test func theStatusLineFollowsWhatTheDaemonReports() {
        #expect(PhoneAccessRules.line(mode: .off, status: Self.up()) == .none, "off shows no line, whatever the status")
        #expect(PhoneAccessRules.line(mode: .lan, status: Self.up()) == .listening("0.0.0.0:7879"))
        let two = PhoneAccessStatus(mode: .tailscale, listening: ["100.64.0.1:7879", "[fd7a:115c:a1e0::1]:7879"])
        #expect(PhoneAccessRules.line(mode: .tailscale, status: two) == .listening("100.64.0.1:7879, [fd7a:115c:a1e0::1]:7879"))
        #expect(PhoneAccessRules.line(mode: .lan, status: nil) == .notListening)
        #expect(PhoneAccessRules.line(mode: .lan, status: PhoneAccessStatus(mode: .lan)) == .notListening)
        let failed = PhoneAccessStatus(mode: .lan, error: "Could not listen on 0.0.0.0:7879: Address already in use.")
        #expect(PhoneAccessRules.line(mode: .lan, status: failed) == .failed("Could not listen on 0.0.0.0:7879: Address already in use."))
        let both = PhoneAccessStatus(mode: .lan, listening: ["[::]:7879"], error: "Could not listen on 0.0.0.0:7879.")
        #expect(PhoneAccessRules.line(mode: .lan, status: both) == .failed("Could not listen on 0.0.0.0:7879."), "a problem is never hidden")
    }

    @Test func aPhoneCanBeConnectedOnlyWhileTheListenerIsUp() {
        #expect(PhoneAccessRules.canConnect(mode: .lan, status: Self.up()))
        #expect(PhoneAccessRules.canConnect(mode: .tailscale, status: Self.up(.tailscale)))
        #expect(!PhoneAccessRules.canConnect(mode: .off, status: Self.up()))
        #expect(!PhoneAccessRules.canConnect(mode: .lan, status: nil))
        #expect(!PhoneAccessRules.canConnect(mode: .lan, status: PhoneAccessStatus(mode: .lan)))
    }

    @Test func theSheetDrawsTheQRCodeOnlyForALinkThatPassedTheCheck() {
        let ok = PairCode(code: Self.code, expiresInMs: 600_000, link: Self.link, hosts: ["x"], fingerprint: Self.fp)
        #expect(
            PhoneAccessRules.pairState(for: ok)
                == .ready(link: Self.link, code: Self.code, hosts: ["100.64.0.1:7879", "192.168.1.5:7879"], expiresInMinutes: 10))
        // The hosts shown are the ones in the link that is drawn, not a separate field that could differ.
        let other = PairCode(code: Self.code, expiresInMs: 90_000, link: Self.link, hosts: ["9.9.9.9:1"])
        #expect(PhoneAccessRules.pairState(for: other)
            == .ready(link: Self.link, code: Self.code, hosts: ["100.64.0.1:7879", "192.168.1.5:7879"], expiresInMinutes: 1))
        #expect(PhoneAccessRules.pairState(for: PairCode(code: "a", expiresInMs: 1)) == .notListening)
        #expect(PhoneAccessRules.pairState(for: PairCode(code: "a", expiresInMs: 1, link: "")) == .notListening)
        let v2 = Self.link.replacingOccurrences(of: "v=1", with: "v=2")
        #expect(PhoneAccessRules.pairState(for: PairCode(code: "a", expiresInMs: 1, link: v2)) == .updateApp)
        for bad in ["bandito://pair?v=1&code=x", "https://evil.example/", Self.link.replacingOccurrences(of: Self.fp, with: "zz")] {
            #expect(PhoneAccessRules.pairState(for: PairCode(code: "a", expiresInMs: 1, link: bad)) == .invalid, "\(bad)")
        }
    }

    @Test func aCodeIsShownForItsLifetimeLessAMoment() {
        let tenMinutes = PairCode(code: "a", expiresInMs: 600_000)
        #expect(PhoneAccessRules.shownFor(tenMinutes) == .milliseconds(598_000))
        #expect(PhoneAccessRules.shownFor(PairCode(code: "a", expiresInMs: 1_000)) == .zero, "a code with no time left is not shown")
        #expect(PhoneAccessRules.shownFor(PairCode(code: "a", expiresInMs: 0)) == .zero)
        #expect(PhoneAccessRules.PairState.expired != .notListening)
    }

    @Test func theSwitchChangeBecomesAPatchAndIsShownAtOnce() {
        let current = ServerSettingValues(
            screenIdleMinutes: 30, maxRunningAgents: 0, backupEveryHours: 24, backupKeep: 14, autoUpdate: .notify,
            updateChannel: "stable", defaultApprovalMode: .risky)
        #expect(ServerSettingChange.phoneAccess(.lan).patch == ServerSettingsPatch(phoneAccess: .lan))
        #expect(ServerSettingChange.phoneAccess(.lan).applied(to: current).phoneAccess == .lan)
        #expect(ServerSettingChange.phoneAccess(.lan).differs(from: current))
        #expect(!ServerSettingChange.phoneAccess(.off).differs(from: current), "the value already set sends nothing")
    }
}
