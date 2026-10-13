import Foundation
import Testing

@testable import BanditoKit

/// The link the iPhone app scans, and the wire shapes around phone access. The expected link below is the one
/// `daemon/src/phone.rs` (`the_link_is_versioned_encoded_and_repeats_host`) builds for the same input.
@Suite struct PhonePairLinkTests {
    private static let fp = String(repeating: "a", count: 64)
    private static let hosts = ["100.64.0.1:7879", "[fd7a:115c:a1e0::1]:7879"]
    private static let code = "otter-lava-mint-orbit-crane-fig"
    private static let daemonLink =
        "bandito://pair?v=1&code=otter-lava-mint-orbit-crane-fig&fp=\(fp)&name=%D0%94%D0%BE%D0%BC%20%26%20Co%20%231&host=100.64.0.1:7879&host=%5Bfd7a:115c:a1e0::1%5D:7879"

    @Test func buildsTheSameLinkAsTheDaemon() {
        #expect(PhonePairLink.make(code: Self.code, fingerprint: Self.fp, name: "Дом & Co #1", hosts: Self.hosts) == Self.daemonLink)
    }

    @Test func readsTheDaemonsLinkBackIntoItsParts() throws {
        let link = try PhonePairLink.parse(Self.daemonLink)
        #expect(link.code == Self.code)
        #expect(link.fingerprint == Self.fp)
        #expect(link.name == "Дом & Co #1")
        #expect(link.hosts == Self.hosts, "order is the preference, IPv6 keeps its brackets")
    }

    @Test func aNameIsCutAtSixtyFourCharacters() throws {
        let text = PhonePairLink.make(code: Self.code, fingerprint: Self.fp, name: String(repeating: "é", count: 100), hosts: Self.hosts)
        #expect(try PhonePairLink.parse(text).name.count == 64)
    }

    @Test func unknownParametersAreIgnored() throws {
        let link = try PhonePairLink.parse(Self.daemonLink + "&future=1&host2=x")
        #expect(link.hosts == Self.hosts)
    }

    @Test func anotherVersionAsksForAnUpdate() {
        let v2 = Self.daemonLink.replacingOccurrences(of: "v=1", with: "v=2")
        #expect(throws: PhonePairLink.Problem.unsupportedVersion) { try PhonePairLink.parse(v2) }
        let none = Self.daemonLink.replacingOccurrences(of: "v=1&", with: "")
        #expect(throws: PhonePairLink.Problem.unsupportedVersion) { try PhonePairLink.parse(none) }
    }

    @Test func brokenLinksAreRefused() {
        let cases: [(String, PhonePairLink.Problem)] = [
            ("https://example.com/pair?v=1", .notALink),
            ("bandito://other?v=1", .notALink),
            ("not a link", .notALink),
            (Self.daemonLink.replacingOccurrences(of: Self.code, with: "otter-lava-mint"), .badCode),
            (Self.daemonLink.replacingOccurrences(of: Self.code, with: "OTTER-LAVA-MINT-ORBIT-CRANE-FIG"), .badCode),
            (Self.daemonLink.replacingOccurrences(of: Self.fp, with: String(repeating: "A", count: 64)), .badFingerprint),
            (Self.daemonLink.replacingOccurrences(of: Self.fp, with: String(repeating: "a", count: 63)), .badFingerprint),
            (Self.daemonLink.replacingOccurrences(of: Self.fp, with: String(repeating: "g", count: 64)), .badFingerprint),
        ]
        for (text, problem) in cases {
            #expect(throws: problem) { try PhonePairLink.parse(text) }
        }
        let noHost = "bandito://pair?v=1&code=\(Self.code)&fp=\(Self.fp)&name=x"
        #expect(throws: PhonePairLink.Problem.noHosts) { try PhonePairLink.parse(noHost) }
    }

    @Test func settingsFromAnOlderDaemonKeepTheirPhoneDefaults() throws {
        let old = #"{"settings":{"screen_idle_minutes":30,"max_running_agents":0,"backup_every_hours":24,"backup_keep":14,"auto_update":"notify","update_channel":"stable","default_approval_mode":"risky"},"defaults":{"screen_idle_minutes":30,"max_running_agents":0,"backup_every_hours":24,"backup_keep":14,"auto_update":"notify","update_channel":"stable","default_approval_mode":"risky"}}"#
        let snapshot = try RPCClient.decoder.decode(ServerSettingsSnapshot.self, from: Data(old.utf8))
        #expect(snapshot.settings.phoneAccess == .off)
        #expect(snapshot.settings.phonePort == 7879)
        #expect(snapshot.phone == nil)
    }

    @Test func settingsFromANewDaemonCarryTheModeAndTheListenerStatus() throws {
        let values = #"{"screen_idle_minutes":30,"max_running_agents":0,"backup_every_hours":24,"backup_keep":14,"auto_update":"notify","update_channel":"stable","default_approval_mode":"risky","phone_access":"tailscale","phone_port":7900}"#
        let phone = #"{"mode":"tailscale","port":7900,"listening":["100.64.0.1:7900"],"error":null,"tls_fingerprint":"\#(Self.fp)"}"#
        let raw = #"{"settings":\#(values),"defaults":\#(values),"phone":\#(phone)}"#
        let snapshot = try RPCClient.decoder.decode(ServerSettingsSnapshot.self, from: Data(raw.utf8))
        #expect(snapshot.settings.phoneAccess == .tailscale)
        #expect(snapshot.settings.phonePort == 7900)
        #expect(snapshot.phone?.listening == ["100.64.0.1:7900"])
        #expect(snapshot.phone?.error == nil)
        #expect(snapshot.phone?.tlsFingerprint == Self.fp)
    }

    @Test func anUnknownModeReadsAsOff() throws {
        let mode = try RPCClient.decoder.decode(PhoneAccessMode.self, from: Data(#""satellite""#.utf8))
        #expect(mode == .off)
    }

    @Test func thePatchSendsSnakeCaseNamesAndOnlyWhatIsSet() throws {
        let data = try RPCClient.encoder.encode(ServerSettingsPatch(phoneAccess: .lan))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["phone_access"] as? String == "lan")
        #expect(json.count == 1)
        #expect(!ServerSettingsPatch(phoneAccess: .off).isEmpty)
    }

    @Test func aPairReplyHasTheLinkOnlyWhenThePhoneListenerIsUp() throws {
        let plain = try RPCClient.decoder.decode(PairCode.self, from: Data(#"{"code":"a-b","expires_in_ms":600000}"#.utf8))
        #expect(plain.link == nil && plain.hosts == nil)
        let off = try RPCClient.decoder.decode(
            PairCode.self, from: Data(#"{"code":"a-b","expires_in_ms":600000,"link":null,"qr":null,"hosts":[],"fingerprint":null}"#.utf8))
        #expect(off.link == nil)
        let on = try RPCClient.decoder.decode(
            PairCode.self,
            from: Data(#"{"code":"a-b","expires_in_ms":600000,"link":"\#(Self.daemonLink)","qr":"x","hosts":["100.64.0.1:7879"],"fingerprint":"\#(Self.fp)"}"#.utf8))
        #expect(on.link == Self.daemonLink)
        #expect(on.hosts == ["100.64.0.1:7879"])
        #expect(on.fingerprint == Self.fp)
    }

    @Test func daemonInfoCarriesTheFingerprintAndTheMode() throws {
        let raw = #"{"version":"0.1.15","hostname":"h","os":"linux","arch":"x86_64","started_at":1,"last_seq":0,"features":["phone_access"],"tls_fingerprint":"\#(Self.fp)","phone_access":"lan"}"#
        let info = try RPCClient.decoder.decode(DaemonInfo.self, from: Data(raw.utf8))
        #expect(info.tlsFingerprint == Self.fp)
        #expect(info.phoneAccess == "lan")
        #expect(info.supports("phone_access"))
        let older = try RPCClient.decoder.decode(
            DaemonInfo.self, from: Data(#"{"version":"0.1.14","hostname":"h","os":"linux","arch":"x","started_at":1,"last_seq":0}"#.utf8))
        #expect(older.tlsFingerprint == nil && older.phoneAccess == nil)
    }

    // MARK: relay (docs/RELAY.md)

    static let sid = "abcdefghijklmnopqrstuvwxyz"
    static let nk = Base64URL.encode(Data((0..<32).map { UInt8($0) }))
    static let relayTail = "&relay=relay.bandito.dev/\(sid)&nk=\(nk)"

    @Test func aLinkWithTheRelayCarriesItAndTheKey() throws {
        let link = try PhonePairLink.parse(Self.daemonLink + Self.relayTail)
        #expect(link.relay == RelayRoute(host: "relay.bandito.dev", sid: Self.sid))
        #expect(link.noiseKey == Self.nk)
        #expect(link.fingerprint == Self.fp && link.hosts == Self.hosts)
        let made = PhonePairLink.make(
            code: Self.code, fingerprint: Self.fp, name: "Дом & Co #1", hosts: Self.hosts, relay: link.relay, noiseKey: Self.nk)
        #expect(made == Self.daemonLink + Self.relayTail)
    }

    @Test func aRelayOnlyLinkHasNoHostAndNoFingerprint() throws {
        let text = "bandito://pair?v=1&code=\(Self.code)&name=Mac\(Self.relayTail)"
        let link = try PhonePairLink.parse(text)
        #expect(link.fingerprint == nil && link.hosts.isEmpty && link.relay?.sid == Self.sid)
        let request = try PairInput.parseLink(text)
        #expect(request.isRelayOnly && request.fingerprint == nil && request.noiseKey == Self.nk)
        // Hosts without a certificate to pin are not worth trying: the relay is the way.
        let hostsOnly = try PairInput.parseLink(text + "&host=10.0.0.2:7879")
        #expect(hostsOnly.hosts.isEmpty)
    }

    @Test func aBrokenRelayPartIsRefusedAndOnlyTheOldLinkNeedsNoRelay() {
        let bad = [
            Self.daemonLink + "&relay=relay.bandito.dev/short&nk=\(Self.nk)",
            Self.daemonLink + "&relay=relay.bandito.dev/\(Self.sid)",
            Self.daemonLink + "&relay=relay.bandito.dev/\(Self.sid)&nk=AAAA",
            Self.daemonLink + "&nk=\(Self.nk)",
            Self.daemonLink + "&relay=evil host/\(Self.sid)&nk=\(Self.nk)",
            Self.daemonLink + "&relay=https://relay.bandito.dev/\(Self.sid)&nk=\(Self.nk)",
        ]
        for text in bad { #expect(throws: PhonePairLink.Problem.badRelay) { try PhonePairLink.parse(text) } }
        #expect(throws: PairInputError.badRelay) { try PairInput.parseLink(bad[0]) }
        // No relay and no fingerprint: nothing to pin, nothing to connect to.
        #expect(throws: PhonePairLink.Problem.badFingerprint) {
            try PhonePairLink.parse("bandito://pair?v=1&code=\(Self.code)&name=x&host=10.0.0.2:7879")
        }
    }

    @Test func relayRoutesAreReadAndTheirAddressIsTLSExceptOnLoopback() {
        #expect(RelayRoute.parse("relay.bandito.dev/\(Self.sid)")?.clientURL?.absoluteString
            == "wss://relay.bandito.dev:443/v1/client/\(Self.sid)")
        #expect(RelayRoute.parse("127.0.0.1:8787/\(Self.sid)")?.clientURL?.scheme == "ws")
        #expect(RelayRoute.parse("example.com:8443/\(Self.sid)")?.clientURL?.absoluteString
            == "wss://example.com:8443/v1/client/\(Self.sid)")
        #expect(RelayRoute.parse("relay.bandito.dev/\(Self.sid)/x") == nil)
        #expect(RelayRoute.parse("/\(Self.sid)") == nil)
        #expect(RelayRoute.parse("relay.bandito.dev/UPPERCASEUPPERCASEUPPERCA") == nil)
    }

    @Test func aPairReplyCarriesTheRelayFields() throws {
        let json = #"{"code":"a-b-c-d-e-f","expires_in_ms":600000,"link":null,"relay":"relay.bandito.dev/\#(Self.sid)","noise_key":"\#(Self.nk)"}"#
        let reply = try RPCClient.decoder.decode(PairCode.self, from: Data(json.utf8))
        #expect(reply.relay == "relay.bandito.dev/\(Self.sid)" && reply.noiseKey == Self.nk)
    }
}
