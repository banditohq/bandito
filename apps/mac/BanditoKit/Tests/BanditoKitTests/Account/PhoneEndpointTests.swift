import Foundation
import Testing

@testable import BanditoKit

/// One server, one entry: how the account's phone record and a device's server entry turn into each other, and how two
/// entries of one daemon collapse.
@Suite struct PhoneEndpointTests {
    static let sid = "abcdefghijklmnopqrstuvwxyz"
    static let nk = Base64URL.encode(Data((0..<32).map { UInt8($0 + 1) }))
    static let nk2 = Base64URL.encode(Data((0..<32).map { UInt8($0 + 50) }))
    static let fp = String(repeating: "ab", count: 32)
    static let route = RelayRoute(host: "relay.bandito.dev", sid: sid)

    @Test func aRecordMakesTheEndpointAndTheEndpointMakesTheSameRecord() throws {
        let both = SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: Self.nk, fp: Self.fp, hosts: ["10.0.0.2:7879"])
        let endpoint = try #require(both.serverEndpoint)
        #expect(endpoint == .reachable(hosts: ["10.0.0.2:7879"], fingerprint: Self.fp, relay: Self.route, noiseKey: Self.nk))
        #expect(SyncedPhone(endpoint: endpoint) == both)

        let cloudOnly = SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: Self.nk)
        #expect(cloudOnly.serverEndpoint == .reachable(hosts: [], fingerprint: nil, relay: Self.route, noiseKey: Self.nk))
        // Direct only keeps the old shape, which older code reads too.
        let direct = SyncedPhone(fp: Self.fp, hosts: ["10.0.0.2:7879"])
        #expect(direct.serverEndpoint == .direct(hosts: ["10.0.0.2:7879"], fingerprint: Self.fp))
        #expect(SyncedPhone(endpoint: .direct(hosts: ["10.0.0.2:7879"], fingerprint: Self.fp)) == direct)
    }

    @Test func aRecordWithNoUsableWayInMakesNothing() {
        #expect(SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: "short").serverEndpoint == nil)
        #expect(SyncedPhone(sid: "BAD", relayHost: "relay.bandito.dev", nk: Self.nk).serverEndpoint == nil)
        #expect(SyncedPhone(fp: "zz", hosts: ["a:1"]).serverEndpoint == nil)
        #expect(SyncedPhone(fp: Self.fp, hosts: []).serverEndpoint == nil)
        #expect(SyncedPhone(endpoint: .webSocket(url: URL(string: "wss://x.example")!)) == nil)
        #expect(SyncedPhone(endpoint: .local(socketPath: "/tmp/x.sock")) == nil)
    }

    @Test func twoRecordsAreOneDaemonWhenTheyShareAKeyAndNoKeyDiffers() {
        let a = SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: Self.nk)
        let b = SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: Self.nk, fp: Self.fp, hosts: ["h:1"])
        #expect(a.isSameDaemon(as: b) && b.isSameDaemon(as: a))
        #expect(SyncedPhone(fp: Self.fp, hosts: ["h:1"]).isSameDaemon(as: b))
        // The same certificate behind another Noise key, or two records with nothing in common, are not.
        #expect(!SyncedPhone(sid: Self.sid, relayHost: "r", nk: Self.nk2, fp: Self.fp, hosts: ["h:1"]).isSameDaemon(as: b))
        #expect(!a.isSameDaemon(as: SyncedPhone(fp: Self.fp, hosts: ["h:1"])))
        #expect(!SyncedPhone().isSameDaemon(as: SyncedPhone()))
    }

    @Test func theServerAnAccessMakesKeepsTheAccountsIdAndTheKeyOfThisDevice() throws {
        let id = UUID()
        let phone = SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: Self.nk)
        let access = ServerAccess(serverID: id, name: "Studio", phone: phone, deviceToken: "bdt_x")
        let key = Data(repeating: 4, count: 32)
        let config = try #require(access.serverConfig(noiseKey: key))
        #expect(config.id == id && config.name == "Studio" && config.token == "bdt_x")
        #expect(config.endpoint.relayPart?.route == Self.route)
        #expect(config.noiseSecret == Base64URL.encode(key))
        // A direct-only record needs no relay key.
        let direct = ServerAccess(serverID: id, name: "x", phone: SyncedPhone(fp: Self.fp, hosts: ["h:1"]), deviceToken: "t")
        #expect(direct.serverConfig(noiseKey: key)?.noiseSecret == nil)
        #expect(ServerAccess(serverID: id, name: "x", phone: SyncedPhone(), deviceToken: "t").serverConfig(noiseKey: key) == nil)
    }

    // MARK: one entry per daemon

    func entry(_ id: String, _ endpoint: SyncedEndpoint, _ phone: SyncedPhone?) -> SyncedServer {
        SyncedServer(id: UUID(uuidString: id)!, name: id, endpoint: endpoint, addedAt: 1, phone: phone)
    }

    @Test func aDaemonAddedOnTwoDevicesIsOneEntryWithTheRicherEndpoint() {
        let mac = entry(
            "00000000-0000-0000-0000-00000000000b", .ssh(host: "h", user: nil, port: nil),
            SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: Self.nk))
        let phone = entry(
            "00000000-0000-0000-0000-00000000000a", .local(deviceID: "phone"),
            SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: Self.nk, fp: Self.fp, hosts: ["10.0.0.2:7879"]))
        for (local, remote) in [(mac, phone), (phone, mac)] {
            let merged = SyncPayload.merged(local: SyncPayload(servers: [local]), remote: SyncPayload(servers: [remote]))
            #expect(merged.servers.count == 1)
            // The ssh entry stays whatever the id order, and takes nothing from the other: an address or a pin one device
            // wrote never becomes another entry's.
            #expect(merged.servers.first?.id == mac.id)
            #expect(merged.servers.first?.phone == mac.phone)
        }
    }

    @Test func entriesWhoseGivenPinsDisagreeStayApartAndNothingIsBorrowed() {
        let real = entry(
            "00000000-0000-0000-0000-00000000000b", .ssh(host: "h", user: nil, port: nil),
            SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: Self.nk, fp: Self.fp, hosts: ["10.0.0.2:7879"]))
        // The same key with another certificate and address: not the same daemon.
        let evil = entry(
            "00000000-0000-0000-0000-00000000000a", .local(deviceID: "phone"),
            SyncedPhone(sid: Self.sid, relayHost: "evil.example", nk: Self.nk, fp: String(repeating: "ee", count: 32), hosts: ["evil:7879"]))
        let merged = SyncPayload.merged(local: SyncPayload(servers: [evil]), remote: SyncPayload(servers: [real]))
        #expect(merged.servers.count == 2)
        #expect(merged.servers.first { $0.id == real.id }?.phone == real.phone)
        // Only a key in common, with the evil one adding pins: the entries collapse, but nothing moves.
        let thin = entry("00000000-0000-0000-0000-00000000000c", .ssh(host: "x", user: nil, port: nil), SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: Self.nk))
        let both = SyncPayload.merged(local: SyncPayload(servers: [evil]), remote: SyncPayload(servers: [thin]))
        #expect(both.servers.count == 1 && both.servers[0].phone == thin.phone)
    }

    @Test func twoEntriesOfTheSameRichnessKeepTheLowerIdAndDifferentDaemonsStayApart() {
        let a = entry("00000000-0000-0000-0000-00000000000a", .local(deviceID: "p1"), SyncedPhone(sid: Self.sid, relayHost: "r", nk: Self.nk))
        let b = entry("00000000-0000-0000-0000-00000000000b", .local(deviceID: "p2"), SyncedPhone(sid: Self.sid, relayHost: "r", nk: Self.nk))
        let other = entry("00000000-0000-0000-0000-00000000000c", .local(deviceID: "p2"), SyncedPhone(sid: "zzzzzzzzzzzzzzzzzzzzzzzzzz", relayHost: "r", nk: Self.nk2))
        let noPhone = entry("00000000-0000-0000-0000-00000000000d", .ssh(host: "x", user: nil, port: nil), nil)
        let merged = SyncPayload.merged(local: SyncPayload(servers: [b, other, noPhone]), remote: SyncPayload(servers: [a]))
        #expect(Set(merged.servers.map(\.id)) == Set([a.id, other.id, noPhone.id]))
    }

    // MARK: publishing what a device was paired with

    @Test func onlyServersWithAWayInAndNotYetInTheBlobArePublished() {
        let paired = ServerConfig(
            name: "Studio", endpoint: .reachable(hosts: [], fingerprint: nil, relay: Self.route, noiseKey: Self.nk), token: "t")
        let ssh = ServerConfig(name: "vps", endpoint: .ssh(server: SSHServerAddress(host: "h"), remotePort: 7878))
        let added = PairedServerPublishing.missing(configs: [paired, ssh], in: SyncPayload(), deviceID: "phone")
        #expect(added.count == 1 && added[0].id == paired.id && added[0].name == "Studio")
        #expect(added[0].endpoint == .local(deviceID: "phone"))
        #expect(added[0].phone == SyncedPhone(sid: Self.sid, relayHost: "relay.bandito.dev", nk: Self.nk))
        // Already there by id, or the same daemon under another id: nothing.
        #expect(PairedServerPublishing.missing(configs: [paired], in: SyncPayload(servers: added), deviceID: "phone").isEmpty)
        var twin = paired
        twin.id = UUID()
        #expect(PairedServerPublishing.missing(configs: [twin], in: SyncPayload(servers: added), deviceID: "phone").isEmpty)
        // Two links to one daemon in one go make one entry.
        #expect(PairedServerPublishing.missing(configs: [paired, twin], in: SyncPayload(), deviceID: "phone").count == 1)
    }

    @Test func theEntryOfALinkPairedServerIsReadableByOlderBuildsAsALocalServer() throws {
        let paired = ServerConfig(
            name: "Studio", endpoint: .reachable(hosts: [], fingerprint: nil, relay: Self.route, noiseKey: Self.nk), token: "t")
        let added = PairedServerPublishing.missing(configs: [paired], in: SyncPayload(), deviceID: "phone")
        let data = try JSONEncoder().encode(SyncPayload(servers: added))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"t\"") && !text.contains("token"))
        let back = try JSONDecoder().decode(SyncPayload.self, from: data)
        #expect(back.servers == added)
    }
}
