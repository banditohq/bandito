import Foundation
import Testing

@testable import BanditoKit

/// The daemon's update check kept on `ServerModel`: a new version of the daemon makes it stale.
@MainActor
@Suite struct DaemonUpdateCheckStateTests {
    static func server() -> ServerModel {
        ServerModel(config: ServerConfig(name: "box", endpoint: .defaultLocal))
    }

    static func info(version: String) throws -> DaemonInfo {
        let json = """
            {"version": "\(version)", "hostname": "box", "os": "linux", "arch": "x86_64",
             "started_at": 1700000000000, "last_seq": 7, "features": ["host", "update"], "update": null}
            """
        return try RPCClient.decoder.decode(DaemonInfo.self, from: Data(json.utf8))
    }

    @Test func checkOfferIsShownFromTheStoredAnswer() throws {
        let server = Self.server()
        server.info = try Self.info(version: "0.1.5")
        server.daemonUpdateCheck = DaemonUpdateCheck(current: "0.1.5", latest: "0.1.9", available: true)
        server.daemonUpdateCheckedAt = Date()
        #expect(server.daemonUpdateOffer?.latest == "0.1.9")
    }

    @Test func sameVersionKeepsTheStoredCheck() throws {
        let server = Self.server()
        server.info = try Self.info(version: "0.1.5")
        server.daemonUpdateCheck = DaemonUpdateCheck(current: "0.1.5", latest: "0.1.9", available: true)
        server.daemonUpdateCheckedAt = Date()
        // A refresh of `daemon.info` at the same version (the hourly one) changes nothing.
        server.info = try Self.info(version: "0.1.5")
        #expect(server.daemonUpdateCheck != nil)
        #expect(server.daemonUpdateCheckedAt != nil)
        #expect(server.daemonUpdateOffer?.latest == "0.1.9")
    }

    @Test func aNewVersionAfterAnUpdateResetsTheCheck() throws {
        let server = Self.server()
        server.info = try Self.info(version: "0.1.5")
        server.daemonUpdateCheck = DaemonUpdateCheck(current: "0.1.5", latest: "0.1.9", available: true)
        server.daemonUpdateCheckedAt = Date()
        // The daemon now runs the release the check named: the stored check and its time are dropped.
        server.info = try Self.info(version: "0.1.9")
        #expect(server.daemonUpdateCheck == nil)
        #expect(server.daemonUpdateCheckedAt == nil)
        #expect(server.daemonUpdateOffer == nil)
    }

    @Test func firstInfoLeavesAnEmptyCheckEmpty() throws {
        let server = Self.server()
        // Nothing was checked yet: the first `daemon.info` leaves the empty state empty.
        server.info = try Self.info(version: "0.1.9")
        #expect(server.daemonUpdateCheck == nil)
        #expect(server.daemonUpdateCheckedAt == nil)
    }

    @Test func anOfflineServerAsksNothingAndKeepsNothing() async {
        let server = Self.server()
        let answer = await server.checkDaemonUpdate()
        #expect(answer == nil)
        #expect(server.daemonUpdateCheck == nil)
        #expect(server.daemonUpdateCheckedAt == nil)
    }
}
