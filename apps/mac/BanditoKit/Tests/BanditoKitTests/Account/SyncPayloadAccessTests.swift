import Foundation
import Testing

@testable import BanditoKit

@Suite struct SyncPayloadAccessTests {
    private let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    private func server(_ id: UUID, phone: SyncedPhone? = nil, name: String = "vps") -> SyncedServer {
        SyncedServer(
            id: id, name: name, endpoint: .ssh(host: "a.example.com", user: nil, port: nil), addedAt: 1, phone: phone)
    }

    private func roundTrip(_ payload: SyncPayload) throws -> SyncPayload {
        try JSONDecoder().decode(SyncPayload.self, from: JSONEncoder().encode(payload))
    }

    @Test func aBlobWrittenBeforeAccessExistedStillReads() throws {
        let old = """
            {"version":1,"servers":[{"id":"00000000-0000-0000-0000-000000000001","name":"vps",\
            "endpoint":{"ssh":{"host":"a.example.com"}},"addedAt":5}],"keymap":"e30="}
            """
        let payload = try JSONDecoder().decode(SyncPayload.self, from: Data(old.utf8))
        #expect(payload.servers.count == 1)
        #expect(payload.servers[0].phone == nil)
        #expect(payload.accessRequests.isEmpty && payload.accessGrants.isEmpty)
        #expect(payload.keymap == Data("{}".utf8))
        // And a payload with none of the new things writes none of them, like before.
        let text = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        #expect(!text.contains("access_") && !text.contains("phone"))
    }

    @Test func thePhoneRecordAndTheListsRoundTripInSnakeCase() throws {
        let phone = SyncedPhone(sid: "S1", relayHost: "relay.bandito.dev", nk: "NK", fp: "ab", hosts: ["10.0.0.2:7879"])
        let payload = SyncPayload(
            servers: [server(id1, phone: phone)],
            accessRequests: [AccessRequest(deviceID: "d2", serverID: id1.uuidString, noiseKey: "k", publicKey: "p", at: 5)],
            accessGrants: [AccessGrant(deviceID: "d2", serverID: id1.uuidString, sealed: "s", at: 6)])
        let text = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        for field in ["relay_host", "access_requests", "access_grants", "device_id", "server_id", "noise_key"] {
            #expect(text.contains("\"\(field)\""), "\(field)")
        }
        #expect(try roundTrip(payload) == payload)
        // The server id is lower case whatever the writer used.
        #expect(try roundTrip(payload).accessRequests[0].serverID == id1.uuidString.lowercased())
    }

    @Test func fieldsThisBuildDoesNotKnowSurviveEveryLevel() throws {
        let future = """
            {"version":1,"theme":{"a":[1,2]},"servers":[{"id":"00000000-0000-0000-0000-000000000001","name":"v",\
            "endpoint":{"local":{"deviceID":"x"}},"addedAt":1,"color":"red",\
            "phone":{"sid":"S","hosts":[],"region":"eu"}}],\
            "access_requests":[{"device_id":"d","server_id":"00000000-0000-0000-0000-000000000001","noise_key":"k","at":9,"note":"hi"}]}
            """
        let payload = try JSONDecoder().decode(SyncPayload.self, from: Data(future.utf8))
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        #expect(again["theme"] != nil)
        let servers = again["servers"] as! [[String: Any]]
        #expect(servers[0]["color"] as? String == "red")
        #expect((servers[0]["phone"] as! [String: Any])["region"] as? String == "eu")
        #expect(((again["access_requests"] as! [[String: Any]])[0])["note"] as? String == "hi")
    }

    @Test func mergeKeepsTheRemotePhoneAndUnknownFieldsOfAServerTheLocalCopyWins() {
        let phone = SyncedPhone(sid: "S1", relayHost: "r", nk: "n", hosts: [])
        var remote = SyncPayload(servers: [server(id1, phone: phone, name: "old")])
        remote.servers[0].extras = ["color": .string("red")]
        remote.extras = ["theme": .string("x")]
        let local = SyncPayload(servers: [server(id1, name: "new"), server(id2)])
        let merged = SyncPayload.merged(local: local, remote: remote, now: now)
        #expect(merged.servers.map(\.name) == ["new", "vps"])
        #expect(merged.servers[0].phone == phone)
        #expect(merged.servers[0].extras["color"] == .string("red"))
        #expect(merged.extras["theme"] == .string("x"))
        // A phone on the local copy wins over the remote one.
        let newer = SyncedPhone(sid: "S2", relayHost: "r", nk: "n", hosts: [])
        let both = SyncPayload.merged(local: SyncPayload(servers: [server(id1, phone: newer)]), remote: remote, now: now)
        #expect(both.servers[0].phone == newer)
    }

    @Test func mergeKeepsTheNewestRequestAndGrantPerDeviceAndServer() {
        func request(_ at: Int64, key: String = "k") -> AccessRequest {
            AccessRequest(deviceID: "d", serverID: id1.uuidString, noiseKey: key, at: at)
        }
        let local = SyncPayload(
            accessRequests: [request(nowMs - 10, key: "local")],
            accessGrants: [AccessGrant(deviceID: "d", serverID: id1.uuidString, sealed: "L", at: nowMs - 5)])
        let remote = SyncPayload(
            accessRequests: [request(nowMs - 20, key: "remote"), AccessRequest(deviceID: "e", serverID: id1.uuidString, noiseKey: "e", at: nowMs)],
            accessGrants: [AccessGrant(deviceID: "d", serverID: id1.uuidString.uppercased(), sealed: "R", at: nowMs - 1)])
        let merged = SyncPayload.merged(local: local, remote: remote, now: now)
        #expect(merged.accessRequests.count == 2)
        #expect(merged.accessRequests.first { $0.deviceID == "d" }?.noiseKey == "local")
        #expect(merged.accessGrants.count == 1)
        #expect(merged.accessGrants[0].sealed == "R")
        // A tie keeps the local copy.
        let tie = SyncPayload.merged(
            local: SyncPayload(accessRequests: [request(nowMs, key: "local")]),
            remote: SyncPayload(accessRequests: [request(nowMs, key: "remote")]), now: now)
        #expect(tie.accessRequests[0].noiseKey == "local")
    }

    @Test func requestsAndGrantsOlderThanAWeekAreDropped() {
        let week = SyncPayload.accessLifetimeMs
        let fresh = AccessRequest(deviceID: "a", serverID: id1.uuidString, noiseKey: "k", at: nowMs - week + 1_000)
        let stale = AccessRequest(deviceID: "b", serverID: id1.uuidString, noiseKey: "k", at: nowMs - week - 1)
        let staleGrant = AccessGrant(deviceID: "b", serverID: id1.uuidString, sealed: "s", at: nowMs - week - 1)
        let payload = SyncPayload(accessRequests: [fresh, stale], accessGrants: [staleGrant])
        let pruned = payload.pruned(now: now)
        #expect(pruned.accessRequests == [fresh])
        #expect(pruned.accessGrants.isEmpty)
        // Every merge prunes.
        #expect(SyncPayload.merged(local: payload, remote: SyncPayload(), now: now).accessRequests == [fresh])
    }

    @Test func aPhoneRecordKnowsWhetherThereIsAWayIn() {
        #expect(!SyncedPhone().isReachable)
        #expect(SyncedPhone(sid: "S", relayHost: "r", nk: "n").isReachable)
        #expect(!SyncedPhone(sid: "S", relayHost: "r").isReachable)
        #expect(SyncedPhone(fp: "ab", hosts: ["h:1"]).isReachable)
        #expect(!SyncedPhone(fp: "ab").isReachable)
        let info = PhoneInfo(relay: "r/S", relayHost: "r", sid: "S", noiseKey: "n", fingerprint: nil, hosts: [])
        #expect(info.synced == SyncedPhone(sid: "S", relayHost: "r", nk: "n"))
        #expect(PhoneInfo().synced == nil)
    }
}
