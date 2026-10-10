import Foundation
import Testing

@testable import BanditoKit

/// A daemon in safe mode refuses `agents.list`. The app must not ask for it, neither by a change event, nor when it
/// comes back to the front, nor in a retry that was already waiting.
@MainActor
@Suite struct SafeModeAgentsTests {
    nonisolated private static let safeInfo =
        #"{"version":"0.1.6","hostname":"test","os":"macos","arch":"arm64","started_at":1,"last_seq":0,"safe_mode":true,"safe_mode_error":"x"}"#

    private func agentListRequests(_ fake: FakeTransport) async -> Int {
        JSONRPC.requests(of: "agents.list", in: await fake.sentTexts()).count
    }

    @Test func noAgentListIsAskedForInSafeMode() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: ["daemon.info": { _ in Self.safeInfo }]))
        let (model, _) = makeModel([fake])
        await model.connect()
        #expect(model.state == .connected)

        await fake.push(
            JSONRPC.notification(
                #"{"seq":1,"agent_id":"a","ts":1,"kind":"agent_changed","payload":{"action":"updated"}}"#))
        model.refreshAgentsIfStale(now: Date().addingTimeInterval(3600))
        try await Task.sleep(for: .milliseconds(600))

        #expect(await agentListRequests(fake) == 0)
        await model.disconnect()
    }

    @Test func aRetryThatWasWaitingDoesNotAskOnceTheDaemonIsInSafeMode() async throws {
        let failing = Switch(on: false)
        let fake = FakeTransport(
            handlers: daemonHandlers(),
            errors: ["agents.list": { _ in failing.isOn ? #"{"code":-32000,"message":"boom"}"# : nil }])
        let (model, _) = makeModel([fake])
        await model.connect()
        model.agentsRetryDelay = .milliseconds(100)

        failing.set(true)
        model.refreshAgentsIfStale(now: Date().addingTimeInterval(3600))
        try await Task.sleep(for: .milliseconds(500))
        let asked = await agentListRequests(fake)
        #expect(asked >= 2, "the read failed and a retry was scheduled")

        // The daemon restarts in safe mode: no more reads.
        model.info = try RPCClient.decoder.decode(DaemonInfo.self, from: Data(Self.safeInfo.utf8))
        try await Task.sleep(for: .milliseconds(800))
        let after = await agentListRequests(fake)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await agentListRequests(fake) == after, "no read after safe mode began")
        await model.disconnect()
    }
}
