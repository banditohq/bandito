import Foundation
import Testing

@testable import BanditoKit

/// What the person gives (a link from the QR code or the clipboard, or an address and a code typed by hand) and how a
/// direct server is saved. The link in `daemon/src/phone.rs` is the source of the format.
@Suite struct PairInputTests {
    private static let fp = String(repeating: "ab", count: 32)
    private static let code = "otter-lava-mint-orbit-crane-fig"

    private static func link(
        v: String = "1", code: String = code, fp: String = fp, name: String = "Studio%20Mac",
        hosts: [String] = ["100.101.102.103:7879", "192.168.1.5:7879"]
    ) -> String {
        "bandito://pair?v=\(v)&code=\(code)&fp=\(fp)&name=\(name)" + hosts.map { "&host=\($0)" }.joined()
    }

    // MARK: Links

    @Test func aDaemonLinkBecomesARequest() throws {
        let request = try PairInput.parseLink(Self.link())
        #expect(request.code == Self.code)
        #expect(request.fingerprint == Self.fp)
        #expect(request.name == "Studio Mac")
        #expect(request.hosts == ["100.101.102.103:7879", "192.168.1.5:7879"])
    }

    @Test func percentEncodingAndIPv6InBracketsAreDecoded() throws {
        let hosts = ["%5Bfd7a:115c:a1e0::1%5D:7879", "mac.local:9000"]
        let request = try PairInput.parseLink(Self.link(name: "D%C3%B6ner%20%26%20Co", hosts: hosts))
        #expect(request.name == "Döner & Co")
        #expect(request.hosts == ["[fd7a:115c:a1e0::1]:7879", "mac.local:9000"])
    }

    @Test func aLinkPastedInsideAMessageStillWorks() throws {
        let text = "  Here you go:\n\(Self.link())\nthanks!  "
        #expect(try PairInput.parseLink(text).code == Self.code)
        #expect(PairInput.containsLink(text))
        #expect(!PairInput.containsLink("https://example.com"))
        #expect(!PairInput.containsLink(""))
    }

    @Test func anotherVersionAsksForAnUpdate() {
        #expect(throws: PairInputError.updateApp) { try PairInput.parseLink(Self.link(v: "2")) }
        #expect(throws: PairInputError.updateApp) { try PairInput.parseLink(Self.link(v: "")) }
    }

    @Test func garbageGivesAPlainError() {
        let cases: [(String, PairInputError)] = [
            ("", .notALink),
            ("hello", .notALink),
            ("https://example.com/pair?code=x", .notALink),
            ("bandito://other?v=1", .notALink),
            (Self.link(code: "one-two"), .badCode),
            (Self.link(code: "ONE-TWO-THREE-FOUR-FIVE-SIX"), .badCode),
            (Self.link(fp: "xyz"), .badFingerprint),
            (Self.link(fp: String(repeating: "A", count: 64)), .badFingerprint),
            (Self.link(hosts: []), .noAddress),
            (Self.link(hosts: ["not%20an%20address", "http:%2F%2Fevil.example"]), .noAddress),
        ]
        for (text, error) in cases {
            #expect(throws: error, "\(text)") { try PairInput.parseLink(text) }
        }
    }

    @Test func unreadableAddressesAreDroppedAndTheOthersKeepTheirOrder() throws {
        let request = try PairInput.parseLink(Self.link(hosts: ["bad%20host", "10.0.0.2:7879", "10.0.0.2:7879", "10.0.0.3"]))
        #expect(request.hosts == ["10.0.0.2:7879", "10.0.0.3:7879"], "duplicates go, a missing port is the default")
    }

    @Test func aMissingOrControlLoadedNameFallsBackToTheAddress() throws {
        #expect(try PairInput.parseLink(Self.link(name: "")).name == "100.101.102.103:7879")
        #expect(try PairInput.parseLink(Self.link(name: "%0A%07%20")).name == "100.101.102.103:7879")
        let long = String(repeating: "x", count: 200)
        #expect(try PairInput.parseLink(Self.link(name: long)).name.count == 64)
    }

    // MARK: Typed by hand

    @Test func anAddressACodeAndAFingerprintAreChecked() throws {
        let request = try PairInput.parseManual(address: " Mac.local ", code: "Otter Lava mint-orbit, crane fig", fingerprint: Self.fp.uppercased())
        #expect(request.hosts == ["mac.local:7879"])
        #expect(request.code == Self.code)
        #expect(request.fingerprint == Self.fp)
        #expect(request.name == "mac.local")
    }

    @Test func theFingerprintMayBeLeftOutButNeverBeWrong() throws {
        #expect(try PairInput.parseManual(address: "10.0.0.5", code: Self.code, fingerprint: "  ").fingerprint == nil)
        #expect(throws: PairInputError.badFingerprint) {
            try PairInput.parseManual(address: "10.0.0.5", code: Self.code, fingerprint: "abc")
        }
        let colons = PinnedFingerprint.display(Self.fp)
        #expect(try PairInput.parseManual(address: "10.0.0.5", code: Self.code, fingerprint: colons).fingerprint == Self.fp)
    }

    @Test func aBadAddressOrCodeIsNamed() {
        #expect(throws: PairInputError.noAddress) { try PairInput.parseManual(address: "  ", code: Self.code, fingerprint: "") }
        #expect(throws: PairInputError.badAddress) { try PairInput.parseManual(address: "http://x", code: Self.code, fingerprint: "") }
        #expect(throws: PairInputError.badAddress) { try PairInput.parseManual(address: "host:99999", code: Self.code, fingerprint: "") }
        #expect(throws: PairInputError.badCode) { try PairInput.parseManual(address: "host", code: "one two three", fingerprint: "") }
        #expect(throws: PairInputError.badCode) { try PairInput.parseManual(address: "host", code: "a b c d e 6", fingerprint: "") }
    }

    // MARK: Addresses

    @Test func addressesReadInEveryShape() {
        #expect(DirectHost.parse("mac.local") == DirectHost(host: "mac.local", port: 7879))
        #expect(DirectHost.parse("Mac.Local:9000") == DirectHost(host: "mac.local", port: 9000))
        #expect(DirectHost.parse("100.64.0.1:7900")?.text == "100.64.0.1:7900")
        #expect(DirectHost.parse("[::1]")?.text == "[::1]:7879")
        #expect(DirectHost.parse("[fd7a:115c:a1e0::1]:7900")?.text == "[fd7a:115c:a1e0::1]:7900")
        #expect(DirectHost.parse("fd7a:115c:a1e0::1")?.text == "[fd7a:115c:a1e0::1]:7879", "a bare IPv6 address has no port")
        #expect(DirectHost.parse("[fd7a::1]")?.rpcURL?.absoluteString == "wss://[fd7a::1]:7879/v1/rpc")
    }

    @Test func notAddressesAreRefused() {
        for bad in ["", " ", "http://mac.local", "mac.local/path", "user@mac.local", "mac local", "mac.local:0", "mac.local:70000",
            "mac.local:abc", "[::1", "[mac.local]:7879", "[::1]x", "::g", "-", ".mac", "mac.", "mac.local?x=1", "mac#x"]
        {
            #expect(DirectHost.parse(bad) == nil, "\(bad)")
        }
    }

    // MARK: Names

    @Test func aNameLosesWhatCouldReorderOrHideText() {
        // U+202E (right-to-left override) would show the rest of the line backwards.
        #expect(ServerNameRules.clean("Mac\u{202E}gpj.exe") == "Macgpj.exe")
        // U+200B (zero width space), U+200D, U+FEFF, U+2066..2069 (isolates), U+2028 / U+2029, and controls.
        #expect(ServerNameRules.clean("a\u{200B}b\u{200D}c\u{FEFF}d\u{2066}e\u{2069}f\u{2028}g\u{2029}h\u{0007}i\u{0000}j") == "abcdefghij")
        #expect(ServerNameRules.clean("  Studio \n Mac  ") == "Studio  Mac", "a line break is dropped like any control")
        #expect(ServerNameRules.clean("\u{202E}\u{200B}", fallback: "10.0.0.2") == "10.0.0.2", "nothing left falls back")
        #expect(ServerNameRules.clean("", fallback: "\u{202E}") == "")
    }

    @Test func aNameKeepsRealTextAndIsCutByScalars() {
        #expect(ServerNameRules.clean("Дом, Köln, 東京 🦝") == "Дом, Köln, 東京 🦝")
        // A letter with a combining accent is two scalars and both stay; many accents are cut at 64 scalars.
        #expect(ServerNameRules.clean("e\u{0301}") == "e\u{0301}")
        let stacked = "e" + String(repeating: "\u{0301}", count: 500)
        #expect(ServerNameRules.clean(stacked).unicodeScalars.count == 64)
        #expect(ServerNameRules.clean(String(repeating: "x", count: 200)).count == 64)
        // A cut never leaves a trailing space.
        #expect(ServerNameRules.clean(String(repeating: "x", count: 63) + " yyyy") == String(repeating: "x", count: 63))
    }

    @Test func aLinkNameIsCleanedToo() throws {
        let request = try PairInput.parseLink(Self.link(name: "Mac%E2%80%AEgpj%E2%80%8B"))
        #expect(request.name == "Macgpj")
        #expect(!request.nameIsGuess)
        #expect(try PairInput.parseManual(address: "mac.local", code: Self.code, fingerprint: "").nameIsGuess)
    }

    @Test func tailscaleAddressesAreRecognised() {
        for yes in ["100.64.0.1", "100.100.100.100", "100.127.255.255", "fd7a:115c:a1e0::1", "[fd7a:115c:a1e0:ab12::9]:7879"] {
            #expect(DirectHost.parse(yes)?.isTailscale == true, "\(yes)")
        }
        for no in ["100.63.255.255", "100.128.0.1", "192.168.1.5", "10.0.0.2", "mac.local", "fd7a:115d:a1e0::1", "::1"] {
            #expect(DirectHost.parse(no)?.isTailscale == false, "\(no)")
        }
    }

    // MARK: Fingerprints

    @Test func fingerprintsNormalizeAndDisplay() {
        #expect(PinnedFingerprint.normalize(Self.fp) == Self.fp)
        #expect(PinnedFingerprint.normalize(Self.fp.uppercased()) == Self.fp)
        #expect(PinnedFingerprint.normalize(PinnedFingerprint.display(Self.fp)) == Self.fp)
        #expect(PinnedFingerprint.normalize(String(Self.fp.dropLast())) == nil)
        #expect(PinnedFingerprint.normalize(Self.fp + "00") == nil)
        #expect(PinnedFingerprint.display("abcdef").hasPrefix("AB:CD:EF"))
        #expect(PinnedFingerprint.of(der: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(PinDelegate.sameFingerprint("ab", "ab"))
        #expect(!PinDelegate.sameFingerprint("ab", "ac"))
        #expect(!PinDelegate.sameFingerprint("ab", "abc"))
    }

    // MARK: The saved server

    @Test func aDirectServerSurvivesSavingAndLoading() throws {
        let config = ServerConfig(name: "Mac", endpoint: .direct(hosts: ["10.0.0.2:7879", "[fd7a::1]:7879"], fingerprint: Self.fp), token: "secret")
        let data = try JSONEncoder().encode([config])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret"), "the token is never in the saved record")
        let back = try JSONDecoder().decode([ServerConfig].self, from: data)
        #expect(back.first?.endpoint == config.endpoint)
        #expect(back.first?.token == nil)
    }

    @Test func oldRecordsStillReadAndDamagedDirectOnesAreRefused() throws {
        let old = #"[{"id":"6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B","name":"Old","endpoint":{"webSocket":{"url":"ws://127.0.0.1:7878/v1/rpc"}}}]"#
        let decoded = try JSONDecoder().decode([ServerConfig].self, from: Data(old.utf8))
        #expect(decoded.first?.endpoint == .webSocket(url: URL(string: "ws://127.0.0.1:7878/v1/rpc")!))
        let ssh = #"[{"id":"6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B","name":"Old","endpoint":{"ssh":{"remotePort":7878,"target":"me@box"}}}]"#
        #expect(try JSONDecoder().decode([ServerConfig].self, from: Data(ssh.utf8)).count == 1)
        func record(_ endpoint: String) -> Data {
            Data(#"[{"id":"6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B","name":"X","endpoint":\#(endpoint)}]"#.utf8)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ServerConfig].self, from: record(#"{"direct":{"hosts":["a:1"],"fingerprint":"short"}}"#))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ServerConfig].self, from: record(#"{"direct":{"hosts":[],"fingerprint":"\#(Self.fp)"}}"#))
        }
        // A fingerprint saved in capitals is normalized, so the pin still compares.
        let upper = try JSONDecoder().decode(
            [ServerConfig].self, from: record(#"{"direct":{"hosts":["a:1"],"fingerprint":"\#(Self.fp.uppercased())"}}"#))
        #expect(upper.first?.endpoint == .direct(hosts: ["a:1"], fingerprint: Self.fp))
    }

    @Test func aDirectServerNamesItsFirstAddressAndIsNotEditableAsAnAddress() {
        let endpoint = ServerEndpoint.direct(hosts: ["10.0.0.2:7879"], fingerprint: Self.fp)
        #expect(ServerAddress(endpoint: endpoint) == .remote("10.0.0.2:7879"))
        #expect(!ServerEndpointRules.isEditable(endpoint))
        #expect(!"\(ServerConfig(name: "Mac", endpoint: endpoint))".contains("10.0.0.2"), "a printed config leaks no address")
    }

    @Test func theLastGoodAddressGoesFirstOnlyIfItIsOneOfTheServers() {
        let memory = DirectHostMemory(defaults: UserDefaults(suiteName: "direct-memory-\(UUID().uuidString)")!)
        let hosts = ["a:1", "b:2", "c:3"]
        #expect(memory.ordered(hosts, for: Self.fp) == hosts)
        memory.remember("c:3", for: Self.fp)
        #expect(memory.ordered(hosts, for: Self.fp) == ["c:3", "a:1", "b:2"])
        memory.remember("gone:9", for: Self.fp)
        #expect(memory.ordered(hosts, for: Self.fp) == hosts, "an address the server no longer lists is ignored")
        memory.forget(Self.fp)
        #expect(memory.lastGood(for: Self.fp) == nil)
    }

    // MARK: Failures in words

    @Test func theListenersLimitIsRateLimitedNotNoAnswer() {
        #expect(WebSocketTransport.httpFailure(forStatus: 429)?.code == RPCError.rateLimited)
        #expect(WebSocketTransport.httpFailure(forStatus: 401)?.code == RPCError.keyRejected)
        #expect(WebSocketTransport.httpFailure(forStatus: 500) == nil)
        #expect(WebSocketTransport.httpFailure(forStatus: nil) == nil)
    }

    @Test func failuresAreToldApart() {
        #expect(PairFailure.classify(RPCError(code: RPCError.unauthorized, message: "invalid or expired code")) == .codeRejected)
        #expect(PairFailure.classify(RPCError(code: RPCError.rateLimited, message: "x")) == .tooManyAttempts)
        #expect(PairFailure.classify(RPCError(code: RPCError.timedOut, message: "x")) == .unreachable)
        #expect(PairFailure.classify(URLError(.cannotConnectToHost)) == .unreachable)
        #expect(PairFailure.classify(RPCError(code: -32602, message: "x")) == .other)
    }
}
