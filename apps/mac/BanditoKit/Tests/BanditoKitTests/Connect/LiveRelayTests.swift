import Foundation
import Testing

@testable import BanditoKit

/// A check against the real relay (`relay.bandito.dev`) with a real daemon of this repository, for a person to run by hand
/// before a release; skipped unless `BANDITO_LIVE_CREDS` names a JSON file `{sid, secret}` of a test registration. It reaches
/// the real service on the network, so it never runs in CI. With `BANDITO_LIVE_HOLD=<dir>` the daemon stays up afterwards:
/// the link of a fresh pairing code is written to `<dir>/link.txt` (for the iPhone app in a simulator) until `<dir>/stop` exists.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BANDITO_LIVE_CREDS"] != nil && DaemonProcess.isAvailable))
struct LiveRelayTests {
    struct Creds: Decodable { var sid: String; var secret: String }

    struct NewAgentParams: Encodable {
        var name: String
        var runtime = "claude"
        var cwd = "/tmp"
    }

    @Test func aPhonePairsAndTalksToARealDaemonThroughTheRealRelayAndARevokeEndsIt() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["BANDITO_LIVE_CREDS"])
        let creds = try JSONDecoder().decode(Creds.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let daemon = try DaemonProcess()
        defer { daemon.stop() }
        let mac = ServerModel(config: daemon.localConfig())
        await mac.connect()
        try #require(mac.state == .connected)

        // The Mac turns the cloud on with the registration (made by hand in the test database).
        let status = try await mac.relayEnable(url: "wss://relay.bandito.dev", sid: creds.sid, secret: creds.secret)
        #expect(status.enabled)
        var connected = false
        for _ in 0..<150 where !connected {
            connected = (try? await mac.relayStatus())?.connected == true
            if !connected { try await Task.sleep(for: .milliseconds(200)) }
        }
        let relay = try await mac.relayStatus()
        try #require(connected, "the daemon reaches relay.bandito.dev: \(relay)")
        print("LIVE relay connected, sid \(creds.sid)")

        // An agent for the phone to see.
        _ = try await mac.rpc().call("agents.create", NewAgentParams(name: "Forge"), as: Agent.self)

        // The phone scans the QR: pairing through the real relay, Noise to the daemon, the token, then ordinary RPC.
        let code = try await mac.createPairCode()
        let link = try #require(code.link)
        #expect(link.contains("relay=relay.bandito.dev/\(creds.sid)"))
        let request = try PairInput.parseLink(link)
        #expect(request.isRelayOnly)
        let paired = try await DevicePairing.redeem(request, fingerprint: nil, deviceName: "Live iPhone")
        #expect(paired.route == .cloud)
        print("LIVE paired through the relay, device \(paired.deviceID)")
        let phone = ServerModel(config: paired.config)
        await phone.connect()
        #expect(phone.state == .connected)
        #expect(phone.connectionRoute == .cloud)
        #expect(phone.agents.map(\.name) == ["Forge"], "daemon.hello, daemon.info and agents.list through the relay")
        print("LIVE phone sees agents \(phone.agents.map(\.name)) via \(String(describing: phone.connectionRoute))")

        // Revoking the device closes its stream at once.
        try await mac.revokeDevice(paired.deviceID)
        var closed = false
        for _ in 0..<100 where !closed {
            if phone.state != .connected { closed = true } else { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(closed, "the revoked device's stream ends")
        print("LIVE revoked device lost its stream")
        await phone.disconnect()

        // For the simulator: a fresh code, and the daemon stays up until told to stop.
        if let hold = ProcessInfo.processInfo.environment["BANDITO_LIVE_HOLD"] {
            let fresh = try #require(try await mac.createPairCode().link)
            try fresh.write(toFile: hold + "/link.txt", atomically: true, encoding: .utf8)
            print("LIVE holding, link written")
            for _ in 0..<4500 where !FileManager.default.fileExists(atPath: hold + "/stop") {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        _ = try? await mac.relayDisable()
        await mac.disconnect()
    }
}
