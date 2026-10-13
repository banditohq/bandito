import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

/// "Servers follow you" end to end: the real daemon of this repository, a relay on loopback that forwards bytes
/// (`RelayBridge`), and two devices of one account that share a fake account service (the blob and the device list in
/// memory). Nothing is mocked between the devices and the daemon: `relay.enable`, the Noise session, `devices.issue`,
/// `pair.redeem`, the device token, the stream that ends when a device is revoked.
///
/// Skipped when the daemon is not built (`cargo build --bin bandito` in `daemon/`).
@MainActor
@Suite(.serialized, .enabled(if: DaemonProcess.isAvailable)) struct PhoneEverywhereTests {
    struct Rig {
        let daemon: DaemonProcess
        let bridge: RelayBridge
        /// The Mac's view of the daemon: its unix socket, the owner.
        let mac: ServerModel
        let serverID = UUID()
        let macIdentity = try! makeIdentity()
        let phoneIdentity = try! makeIdentity()

        func devices() -> [AccountDevice] {
            [
                AccountDevice(id: "mac", name: "Studio", platform: "macos", approved: true, publicKey: macIdentity.publicKeyBase64),
                AccountDevice(id: "phone", name: "Anna's iPhone", platform: "ios", approved: true, publicKey: phoneIdentity.publicKeyBase64),
            ]
        }

        func stop() async {
            await mac.disconnect()
            bridge.stop()
            daemon.stop()
        }
    }

    /// A registrar that hands out the bridge's registration, like the platform does after `POST /relay/servers`.
    actor BridgeRegistrar: RelayRegistrar {
        let sid: String, secret: String, url: String
        init(_ bridge: RelayBridge) {
            sid = bridge.sid
            secret = bridge.secret
            url = bridge.url
        }
        func registerRelayServer(name: String) async throws -> RelayRegistration {
            RelayRegistration(sid: sid, secret: secret, relayURL: url)
        }
        func relayServers() async throws -> [RelayServerEntry] { [] }
        func deleteRelayServer(sid: String) async throws {}
    }

    /// What a device does with an access: builds the server the way the apps do, from the record and the key made for it.
    actor Sink: ServerAccessSink {
        let noiseKeys: ServerNoiseKeyStore
        var configs: [ServerConfig] = []
        var holdsPhone: SyncedPhone?
        init(noiseKeys: ServerNoiseKeyStore) { self.noiseKeys = noiseKeys }
        func hasAccess(serverID: UUID) async -> Bool { configs.contains { $0.id == serverID } }
        func hasAccess(serverID: UUID, phone: SyncedPhone?) async -> Bool {
            if configs.contains(where: { $0.id == serverID }) { return true }
            if let phone, configs.contains(where: { phone.isSameDaemon(as: $0.endpoint) }) { return true }
            if let phone, let holdsPhone, phone.isSameDaemon(as: holdsPhone) { return true }
            return false
        }
        func receive(_ access: ServerAccess) async throws {
            let key = try noiseKeys.privateKey(for: access.serverID)
            guard let config = access.serverConfig(noiseKey: key) else { throw URLError(.badURL) }
            configs.append(config)
        }
        func hold(_ phone: SyncedPhone) { holdsPhone = phone }
    }

    func start() async throws -> Rig {
        let daemon = try DaemonProcess()
        let bridge = try RelayBridge()
        let id = UUID()
        let mac = ServerModel(config: daemon.localConfig(id: id))
        await mac.connect()
        try #require(mac.state == .connected, "the daemon answers on its socket")
        // The cloud on, through the same controller the app uses: register (a fake platform), hand over, wait.
        let controller = RelayController(
            host: mac, registrar: { BridgeRegistrar(bridge) }, connectTimeout: .seconds(15), pollInterval: .milliseconds(100))
        let connected = await controller.enable()
        try #require(connected, "the daemon reaches the relay: \(String(describing: controller.problem))")
        #expect(bridge.daemonConnected)
        return Rig(daemon: daemon, bridge: bridge, mac: mac)
    }

    /// The blob with the server as the Mac publishes it: its phone record comes from the daemon's own `phone.info`.
    func macBlob(_ rig: Rig) async throws -> SyncPayload {
        let record = try #require(await PhoneRecords.collect(from: [rig.mac])[rig.mac.accessServerID])
        return SyncPayload(servers: [
            SyncedServer(id: rig.mac.accessServerID, name: "Studio", endpoint: .local(deviceID: "mac"), addedAt: 1, phone: record)
        ])
    }

    @Test func aMacIssuesAndAPhoneConnectsThroughTheRelayThenARevokeCutsItOff() async throws {
        let rig = try await start()
        defer { Task { await rig.stop() } }
        let sync = AccessFakeSync(try await macBlob(rig))
        let record = try #require(sync.payload?.servers.first?.phone)
        #expect(record.sid == rig.bridge.sid && record.relayHost == "127.0.0.1:\(rig.bridge.port)")
        #expect(record.nk?.count == 43)

        let devices = rig.devices()
        // One key store for the device: the key the request carries is the key the connection speaks with.
        let phoneKeys = ServerNoiseKeyStore(secrets: MemorySecretStore())
        let phoneSink = Sink(noiseKeys: phoneKeys)
        let ledger = AccessLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let responder = AccessResponder(
            sync: sync, account: AccessFakeAccount(deviceID: "mac", devices: devices), identity: rig.macIdentity, ledger: ledger)
        let requester = AccessRequester(
            sync: sync, account: AccessFakeAccount(deviceID: "phone", devices: devices), identity: rig.phoneIdentity,
            sink: phoneSink, noiseKeys: phoneKeys, defaults: UserDefaults(suiteName: UUID().uuidString)!)

        // The phone signs in: it sees the server, has no token and asks. The Mac answers through the real daemon.
        _ = try await requester.run()
        #expect(sync.payload?.accessRequests.count == 1)
        let outcome = try await responder.run(servers: [rig.mac])
        #expect(outcome.issued == 1)
        let states = try await requester.run()
        #expect(states.map(\.status) == [.connected])
        let config = try #require(await phoneSink.configs.first)
        #expect(config.id == rig.mac.accessServerID, "one server, one id on both devices")
        guard case .reachable(let hosts, _, let route, _) = config.endpoint else {
            Issue.record("the record makes a relay server: \(config.endpoint)")
            return
        }
        #expect(route?.sid == rig.bridge.sid && hosts.isEmpty)

        // The phone connects: Noise through the relay, the token it was issued, then ordinary RPC.
        let phone = ServerModel(config: config)
        await phone.connect()
        #expect(phone.state == .connected)
        #expect(phone.connectionRoute == .cloud)
        #expect(phone.info?.hostname.isEmpty == false)
        #expect(rig.bridge.streamsOpened >= 1)

        // The device the Mac issued is on the daemon, with the phone's key; revoking it ends the phone's stream.
        let rows = try await rig.mac.devices()
        let row = try #require(rows.first { $0.name == "Anna's iPhone" })
        try await rig.mac.revokeDevice(row.id)
        var closed = false
        for _ in 0..<100 where !closed {
            if phone.state != .connected { closed = true } else { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(closed, "the stream of a revoked device ends")
        // And it cannot come back: its token is gone.
        let again = RPCClient(transport: ReachableTransport(config: config))
        await #expect(throws: (any Error).self) {
            try await again.start()
            _ = try await again.call("daemon.info", NoParams(), as: DaemonInfo.self, timeout: .seconds(5))
        }
        await again.close()
        await phone.disconnect()
    }

    @Test func aServerAddedOnThePhoneByQRReachesTheMacWithoutADuplicate() async throws {
        let rig = try await start()
        defer { Task { await rig.stop() } }

        // The phone scans the daemon's QR: pairing through the relay, a token and its own Noise key.
        let code = try await rig.mac.createPairCode()
        let link = try #require(code.link)
        let request = try PairInput.parseLink(link)
        let paired = try await DevicePairing.redeem(request, fingerprint: request.fingerprint, deviceName: "Anna's iPhone")
        #expect(paired.route == .cloud)
        let phoneServer = ServerModel(config: paired.config)
        await phoneServer.connect()
        try #require(phoneServer.state == .connected)

        // The phone publishes it for the account (an empty blob: nothing else knows this server yet).
        let sync = AccessFakeSync(SyncPayload())
        let added = try await PairedServerPublishing.publish(
            configs: [paired.config], to: sync, deviceID: "phone")
        #expect(added == 1)
        let entry = try #require(sync.payload?.servers.first)
        #expect(entry.id == paired.config.id)
        #expect(entry.phone?.sid == rig.bridge.sid)
        // Publishing again adds nothing; the same daemon by another id adds nothing either.
        #expect(try await PairedServerPublishing.publish(configs: [paired.config], to: sync, deviceID: "phone") == 0)
        var twin = paired.config
        twin.id = UUID()
        #expect(try await PairedServerPublishing.publish(configs: [twin], to: sync, deviceID: "phone") == 0)

        // The Mac asks; the phone, connected to the daemon as a device, answers: `devices.issue` over the relay.
        let devices = rig.devices()
        let macKeys = ServerNoiseKeyStore(secrets: MemorySecretStore())
        let macSink = Sink(noiseKeys: macKeys)
        let requester = AccessRequester(
            sync: sync, account: AccessFakeAccount(deviceID: "mac", devices: devices), identity: rig.macIdentity, sink: macSink,
            noiseKeys: macKeys, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let responder = AccessResponder(
            sync: sync, account: AccessFakeAccount(deviceID: "phone", devices: devices), identity: rig.phoneIdentity,
            ledger: AccessLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        _ = try await requester.run()
        #expect(sync.payload?.accessRequests.first?.deviceID == "mac")
        let outcome = try await responder.run(servers: [phoneServer])
        #expect(outcome.issued == 1, "an ordinary device may issue: \(outcome)")
        _ = try await requester.run()
        let config = try #require(await macSink.configs.first)
        #expect(config.id == paired.config.id)
        let second = ServerModel(config: config)
        await second.connect()
        #expect(second.state == .connected && second.connectionRoute == .cloud)
        await second.disconnect()
        await phoneServer.disconnect()
    }

    @Test func theMacsOwnServerIsNotAskedForAgainWhenThePhoneAddedItToo() async throws {
        let rig = try await start()
        defer { Task { await rig.stop() } }
        var blob = try await macBlob(rig)
        let sync = AccessFakeSync(blob)

        // The phone pairs by QR the same daemon the Mac already published.
        let request = try PairInput.parseLink(try #require(try await rig.mac.createPairCode().link))
        let paired = try await DevicePairing.redeem(request, fingerprint: nil, deviceName: "Anna's iPhone")
        #expect(try await PairedServerPublishing.publish(configs: [paired.config], to: sync, deviceID: "phone") == 0)
        blob = try #require(sync.payload)
        #expect(blob.servers.count == 1)

        // Its own server under its own id counts as the account's: no request for the Mac's entry.
        let sink = Sink(noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()))
        await sink.hold(try #require(SyncedPhone(endpoint: paired.config.endpoint)))
        let requester = AccessRequester(
            sync: sync, account: AccessFakeAccount(deviceID: "phone", devices: rig.devices()), identity: rig.phoneIdentity,
            sink: sink, noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()),
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let states = try await requester.run()
        #expect(states.map(\.status) == [.connected])
        #expect(sync.payload?.accessRequests.isEmpty == true)
    }
}
