import Foundation
import Testing

@testable import BanditoKit

/// The direct connection to a daemon's phone listener, against a fake server with TLS on loopback: the pin decides
/// everything, the addresses are tried in order with a time limit each, and pairing swaps the code for a token.
@Suite(.serialized) struct DirectTransportTests {
    private func memory() -> DirectHostMemory {
        DirectHostMemory(defaults: UserDefaults(suiteName: "direct-test-\(UUID().uuidString)")!)
    }

    private func hello(_ transport: DirectTransport) async throws -> String {
        try await transport.send(#"{"jsonrpc":"2.0","id":1,"method":"daemon.hello","params":{}}"#)
        return try await transport.receive()
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func aServerWithTheRightCertificateAnswers() async throws {
        let server = try TLSTestServer()
        defer { server.stop() }
        let transport = DirectTransport(
            hosts: [server.address], fingerprint: TLSTestServer.fingerprintA, token: nil, memory: memory())
        try await transport.connect()
        #expect(try await hello(transport).contains("authenticated"))
        #expect(await transport.connectedHost == server.address)
        await transport.close()
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func aServerWithAnotherCertificateIsRefusedAndSaysWhy() async throws {
        let server = try TLSTestServer(certificate: .b)
        defer { server.stop() }
        let transport = DirectTransport(
            hosts: [server.address], fingerprint: TLSTestServer.fingerprintA, token: nil, memory: memory())
        await #expect(throws: RPCError.fingerprintMismatch) { try await transport.connect() }
        #expect(await transport.connectedHost == nil)
        #expect(FailureKind.classify(RPCError.fingerprintMismatch) == .reason("fingerprint_mismatch"))
        #expect(PairFailure.classify(RPCError.fingerprintMismatch) == .fingerprintMismatch)
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func theSystemTrustStoreIsNeverAskedAndAnUpperCasePinStillMatches() async throws {
        let server = try TLSTestServer()
        defer { server.stop() }
        // A self-signed certificate is no use to the system: only the pin lets it through.
        let transport = DirectTransport(
            hosts: [server.address], fingerprint: TLSTestServer.fingerprintA.uppercased(), token: nil, memory: memory())
        try await transport.connect()
        await transport.close()
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func aBrokenPinRefusesToConnectAtAll() async throws {
        let server = try TLSTestServer()
        defer { server.stop() }
        for pin in ["", "abc", String(repeating: "z", count: 64)] {
            let transport = DirectTransport(hosts: [server.address], fingerprint: pin, token: nil, memory: memory())
            await #expect(throws: RPCError.self) { try await transport.connect() }
        }
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func theAddressesAreTriedInOrderAndTheOneThatWorkedIsRemembered() async throws {
        let server = try TLSTestServer()
        let silent = try TLSTestServer(tls: false)
        defer {
            server.stop()
            silent.stop()
        }
        let memory = memory()
        let hosts = ["127.0.0.1:1", silent.address, server.address]
        let first = DirectTransport(
            hosts: hosts, fingerprint: TLSTestServer.fingerprintA, token: nil, hostTimeout: .milliseconds(700), memory: memory)
        let started = ContinuousClock.now
        try await first.connect()
        // The refused port fails at once; the silent one costs its time limit; the third answers.
        #expect(await first.connectedHost == server.address)
        #expect(ContinuousClock.now - started < .seconds(5))
        await first.close()
        #expect(memory.lastGood(for: TLSTestServer.fingerprintA) == server.address)
        // The next connection starts with it.
        #expect(memory.ordered(hosts, for: TLSTestServer.fingerprintA) == [server.address, "127.0.0.1:1", silent.address])
        let second = DirectTransport(
            hosts: hosts, fingerprint: TLSTestServer.fingerprintA, token: nil, hostTimeout: .milliseconds(700), memory: memory)
        let again = ContinuousClock.now
        try await second.connect()
        #expect(ContinuousClock.now - again < .milliseconds(600), "no time lost on the dead addresses")
        await second.close()
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func nothingAnsweringIsNoAnswerNotAMismatch() async throws {
        let silent = try TLSTestServer(tls: false)
        defer { silent.stop() }
        let transport = DirectTransport(
            hosts: ["127.0.0.1:1", silent.address], fingerprint: TLSTestServer.fingerprintA, token: nil,
            hostTimeout: .milliseconds(500), memory: memory())
        do {
            try await transport.connect()
            Issue.record("it connected to nothing")
        } catch {
            #expect(PairFailure.classify(error) == .unreachable)
            #expect(FailureKind.classify(error) == .noAnswer)
        }
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func aWrongCertificateOnOneAddressDoesNotStopTheNextOne() async throws {
        let impostor = try TLSTestServer(certificate: .b)
        let real = try TLSTestServer()
        defer {
            impostor.stop()
            real.stop()
        }
        let transport = DirectTransport(
            hosts: [impostor.address, real.address], fingerprint: TLSTestServer.fingerprintA, token: nil, memory: memory())
        try await transport.connect()
        #expect(await transport.connectedHost == real.address)
        await transport.close()
    }

    @Test func noAddressMeansNoAnswer() async {
        let transport = DirectTransport(hosts: [], fingerprint: TLSTestServer.fingerprintA, token: nil, memory: memory())
        await #expect(throws: RPCError.self) { try await transport.connect() }
        let unreadable = DirectTransport(
            hosts: ["not an address"], fingerprint: TLSTestServer.fingerprintA, token: nil, memory: memory())
        await #expect(throws: RPCError.self) { try await unreadable.connect() }
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func theProbeReadsTheFingerprintWithoutTrustingIt() async throws {
        let a = try TLSTestServer(certificate: .a)
        let b = try TLSTestServer(certificate: .b)
        defer {
            a.stop()
            b.stop()
        }
        #expect(await FingerprintProbe.fetch(host: DirectHost.parse(a.address)!, timeout: .seconds(4)) == TLSTestServer.fingerprintA)
        #expect(await FingerprintProbe.fetch(host: DirectHost.parse(b.address)!, timeout: .seconds(4)) == TLSTestServer.fingerprintB)
        #expect(await FingerprintProbe.fetch(host: DirectHost(host: "127.0.0.1", port: 1), timeout: .seconds(2)) == nil)
    }

    // MARK: Pairing

    private func request(_ server: TLSTestServer, code: String = TLSTestServer.validCode) -> PairRequest {
        PairRequest(code: code, fingerprint: TLSTestServer.fingerprintA, name: "Fake server", hosts: ["127.0.0.1:1", server.address])
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func aGoodCodeBecomesADirectServerWithItsToken() async throws {
        let server = try TLSTestServer()
        defer { server.stop() }
        let paired = try await DevicePairing.redeem(
            request(server), fingerprint: TLSTestServer.fingerprintA, deviceName: "Anna's iPhone",
            hostTimeout: .milliseconds(700), memory: memory())
        #expect(paired.config.token == TLSTestServer.token)
        #expect(paired.config.name == "Fake server")
        #expect(paired.deviceID == "dev-1")
        // The address that answered goes first.
        #expect(paired.config.endpoint == .direct(hosts: [server.address, "127.0.0.1:1"], fingerprint: TLSTestServer.fingerprintA))
        #expect(server.redeems == 1)
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func aWrongCodeIsRefusedAndNothingIsSaved() async throws {
        let server = try TLSTestServer()
        defer { server.stop() }
        do {
            _ = try await DevicePairing.redeem(
                request(server, code: "wrong-wrong-wrong-wrong-wrong-wrong"), fingerprint: TLSTestServer.fingerprintA,
                deviceName: "x", hostTimeout: .milliseconds(700), memory: memory())
            Issue.record("a wrong code paired")
        } catch {
            #expect(PairFailure.classify(error) == .codeRejected)
        }
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func theCodeIsNeverSentToAServerWithAnotherCertificate() async throws {
        let impostor = try TLSTestServer(certificate: .b)
        defer { impostor.stop() }
        do {
            _ = try await DevicePairing.redeem(
                PairRequest(code: TLSTestServer.validCode, fingerprint: TLSTestServer.fingerprintA, name: "x", hosts: [impostor.address]),
                fingerprint: TLSTestServer.fingerprintA, deviceName: "x", memory: memory())
            Issue.record("paired with an impostor")
        } catch {
            #expect(PairFailure.classify(error) == .fingerprintMismatch)
        }
        #expect(impostor.redeems == 0, "the one-time code stayed on the phone")
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func anAddressTypedByHandTakesTheNameOfTheServer() async throws {
        let server = try TLSTestServer()
        defer { server.stop() }
        let request = try PairInput.parseManual(address: server.address, code: TLSTestServer.validCode, fingerprint: "")
        #expect(request.name == "127.0.0.1", "the typed address is only a guess")
        let paired = try await DevicePairing.redeem(
            request, fingerprint: TLSTestServer.fingerprintA, deviceName: "x", hostTimeout: .milliseconds(700), memory: memory())
        #expect(paired.config.name == "fake", "the daemon's host name, not 127.0.0.1")
        // A name from a link is the person's own choice at the Mac: it is kept.
        let linked = try await DevicePairing.redeem(
            PairRequest(code: TLSTestServer.validCode, fingerprint: TLSTestServer.fingerprintA, name: "Studio", hosts: [server.address]),
            fingerprint: TLSTestServer.fingerprintA, deviceName: "x", hostTimeout: .milliseconds(700), memory: memory())
        #expect(linked.config.name == "Studio")
    }

    @Test(.enabled(if: TLSTestServer.isSupported))
    func disconnectingAsksTheServerToForgetThisDevice() async throws {
        let server = try TLSTestServer()
        defer { server.stop() }
        let config = ServerConfig(
            name: "Mac", endpoint: .direct(hosts: [server.address], fingerprint: TLSTestServer.fingerprintA), token: "tok")
        #expect(await DevicePairing.revokeSelf(config: config, timeout: .seconds(4)))
        #expect(server.revokes == 1)
        server.stop()
        #expect(!(await DevicePairing.revokeSelf(config: config, timeout: .seconds(2))), "an unreachable server is reported, not thrown")
    }

    @Test func aRedirectIsNeverFollowed() async {
        let delegate = PinDelegate(expected: String(repeating: "a", count: 64))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://127.0.0.1:1/")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://elsewhere.example/"])!
        let followed: URLRequest?? = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://elsewhere.example/")!)) {
                continuation.resume(returning: .some($0))
            }
        }
        #expect(followed == .some(nil), "the delegate answers nil: the redirect is refused")
    }

    @Test func aBadFingerprintStopsBeforeAnyConnection() async {
        let request = PairRequest(code: TLSTestServer.validCode, fingerprint: nil, name: "x", hosts: ["127.0.0.1:1"])
        await #expect(throws: PairInputError.badFingerprint) {
            _ = try await DevicePairing.redeem(request, fingerprint: "nope", deviceName: "x")
        }
    }
}
