import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

/// The relay connection against a fake relay and daemon on loopback: Noise, auth, RPC, the limits, the words for failures.
@Suite(.serialized) struct RelayTransportTests {
    func phoneKey() -> Curve25519.KeyAgreement.PrivateKey { Curve25519.KeyAgreement.PrivateKey() }

    func request(on relay: FakeRelay, key: Curve25519.KeyAgreement.PrivateKey, role: RelayTransport.Role) -> RelayTransport {
        RelayTransport(
            route: relay.route, daemonKey: relay.daemonPublicKey, phoneKey: key, role: role, timeout: .seconds(5),
            keepalive: .milliseconds(150))
    }

    @Test func pairsThroughTheRelayAndThenSignsInWithItsToken() async throws {
        let relay = try FakeRelay()
        defer { relay.stop() }
        let key = phoneKey()
        let link = PhonePairLink.make(
            code: FakeRelay.validCode, fingerprint: nil, name: "Studio", hosts: [], relay: relay.route,
            noiseKey: Base64URL.encode(relay.daemonPublicKey))
        let parsed = try PairInput.parseLink(link)
        #expect(parsed.isRelayOnly)

        let paired = try await DevicePairing.redeem(parsed, fingerprint: nil, deviceName: "Anna's iPhone")
        #expect(paired.config.token == FakeRelay.token)
        guard case .reachable(let hosts, let fp, let route, let nk) = paired.config.endpoint else {
            Issue.record("a relay link makes a reachable server")
            return
        }
        #expect(hosts.isEmpty && fp == nil && route == relay.route && nk == Base64URL.encode(relay.daemonPublicKey))
        let secret = try #require(paired.config.noisePrivateKey)
        // The daemon saw the public half of the key this device keeps.
        #expect(relay.redeemed.first?.noiseKey == Base64URL.encode(secret.publicKey.rawRepresentation))
        #expect(relay.redeemed.first?.name == "Anna's iPhone")
        _ = key

        // A second session with the stored config: auth with the token, then ordinary RPC.
        let transport = ReachableTransport(config: paired.config)
        let client = RPCClient(transport: transport)
        try await client.start()
        let hello = try await client.call("daemon.hello", NoParams(), as: Hello.self, timeout: .seconds(5))
        #expect(hello.authenticated == true)
        #expect(await transport.connectedRoute == .cloud)
        await client.close()
    }

    struct Hello: Decodable { var authenticated: Bool? }

    @Test func aLargeReplyIsJoinedFromChunks() async throws {
        let relay = try FakeRelay()
        defer { relay.stop() }
        let key = phoneKey()
        relay.learnForTests(key)
        let client = RPCClient(transport: request(on: relay, key: key, role: .device(token: FakeRelay.token)))
        try await client.start()
        struct Big: Decodable { var text: String }
        let big = try await client.call("big.echo", NoParams(), as: Big.self, timeout: .seconds(5))
        #expect(big.text.count == 150_000)
        await client.close()
    }

    @Test func aTokenOfAnotherKeyIsRefusedAndTheReasonIsKept() async throws {
        let relay = try FakeRelay()
        defer { relay.stop() }
        // This phone key was never paired.
        let client = RPCClient(transport: request(on: relay, key: phoneKey(), role: .device(token: FakeRelay.token)))
        do {
            try await client.start()
            _ = try await client.call("daemon.info", NoParams(), as: Hello.self, timeout: .seconds(5))
            Issue.record("must be refused")
        } catch {
            #expect(FailureKind.classify(error) == .keyRejected)
        }
        await client.close()
    }

    @Test func aWrongDaemonKeyIsNotTrusted() async throws {
        let relay = try FakeRelay()
        defer { relay.stop() }
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let transport = RelayTransport(
            route: relay.route, daemonKey: other, phoneKey: phoneKey(), role: .pairing, timeout: .seconds(2))
        await #expect(throws: RPCError.self) { try await transport.connect() }
        do { try await transport.connect() } catch {
            #expect(FailureKind.classify(error) == .reason(RelayFailure.keyMismatch))
        }
    }

    @Test func closeCodesAndStatusesBecomeWords() {
        #expect(FailureKind.classify(RelayFailure.error(forClose: 4008)) == .reason("relay_limit"))
        #expect(FailureKind.classify(RelayFailure.error(forClose: 4010)) == .reason("relay_busy"))
        #expect(FailureKind.classify(RelayFailure.error(forClose: 4003)) == .reason("relay_offline"))
        // Replaced, silence, server left, oversize, no first frame: a quiet reconnect (a lost link).
        for code in [4001, 4002, 4004, 4009, 4011, 1006] {
            #expect(FailureKind.classify(RelayFailure.error(forClose: code)) == .noAnswer)
        }
        #expect(FailureKind.classify(RelayFailure.error(forStatus: 503)!) == .reason("relay_offline"))
        #expect(FailureKind.classify(RelayFailure.error(forStatus: 429)!) == .reason("relay_busy"))
        #expect(RelayFailure.error(forStatus: 200) == nil)
        #expect(FailureKind.classify(RelayFailure.error(forDaemon: "unauthorized")) == .keyRejected)
        #expect(FailureKind.classify(RelayFailure.error(forDaemon: "server_error")) == .noAnswer)
    }

    @Test func aLimitCloseReachesTheApp() async throws {
        let relay = try FakeRelay()
        defer { relay.stop() }
        relay.closeCodeOnOpen = 4008
        let transport = request(on: relay, key: phoneKey(), role: .pairing)
        do {
            try await transport.connect()
            Issue.record("must end")
        } catch {
            #expect(FailureKind.classify(error) == .reason("relay_limit"))
        }
    }

    @Test func silenceEndsWithATimeoutAndNothingIsLeftOpen() async throws {
        let relay = try FakeRelay()
        defer { relay.stop() }
        relay.silent = true
        let transport = RelayTransport(
            route: relay.route, daemonKey: relay.daemonPublicKey, phoneKey: phoneKey(), role: .pairing, timeout: .milliseconds(400))
        do {
            try await transport.connect()
            Issue.record("must time out")
        } catch let error as RPCError {
            #expect(error.code == RPCError.timedOut)
        }
    }

    @Test func theRelaysPingIsAnsweredAndTheAppPingsToo() async throws {
        let relay = try FakeRelay()
        defer { relay.stop() }
        relay.pingAfterHandshake = true
        let client = RPCClient(transport: request(on: relay, key: phoneKey(), role: .pairing))
        try await client.start()
        _ = try? await client.call("daemon.hello", NoParams(), as: Hello.self, timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(500))
        #expect(relay.texts.contains("pong"))
        #expect(relay.texts.contains("ping"))
        await client.close()
    }

    @Test func theFirstMessageNamesTheRole() {
        #expect(RelayTransport.firstMessage(for: .pairing) == #"{"pair":true}"#)
        #expect(RelayTransport.firstMessage(for: .device(token: "a\"b")) == #"{"auth":"a\"b"}"#)
        #expect(RelayTransport.daemonRefusal(in: #"{"error":"rate_limited"}"#) == "rate_limited")
        #expect(RelayTransport.daemonRefusal(in: #"{"jsonrpc":"2.0","id":1,"error":{"code":1}}"#) == nil)
        #expect(RelayTransport.daemonRefusal(in: "not json") == nil)
    }
}

extension FakeRelay {
    /// Pretends this key paired earlier.
    func learnForTests(_ key: Curve25519.KeyAgreement.PrivateKey) {
        learn(key: key.publicKey.rawRepresentation)
    }
}
