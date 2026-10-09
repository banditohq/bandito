import Foundation
import Testing

@testable import BanditoKit

@Suite struct DaemonUpdateTests {
    /// A `daemon.info` reply as the daemon sends it: snake_case keys, `update` as given.
    static func info(update: String?, version: String = "0.2.0") throws -> DaemonInfo {
        let updateField = update.map { ", \"update\": \($0)" } ?? ""
        let json = """
            {"version": "\(version)", "hostname": "box", "os": "linux", "arch": "x86_64",
             "started_at": 1700000000000, "last_seq": 7, "features": ["host"]\(updateField)}
            """
        return try RPCClient.decoder.decode(DaemonInfo.self, from: Data(json.utf8))
    }

    @Test func nullUpdateDecodesAsNoCheckResult() throws {
        let info = try Self.info(update: "null")
        #expect(info.update == nil)
        #expect(DaemonUpdateOffer.offer(for: info) == nil)
    }

    @Test func missingUpdateFieldIsNoCheckResult() throws {
        // A daemon older than the update check does not send the field at all.
        let info = try Self.info(update: nil)
        #expect(info.update == nil)
        #expect(info.version == "0.2.0")
    }

    @Test func updateDecodesWithItsFields() throws {
        let update = #"{"current": "0.2.0", "latest": "0.3.0", "available": true, "checked_at": 1700000001000}"#
        let info = try Self.info(update: update)
        #expect(info.update == DaemonUpdate(current: "0.2.0", latest: "0.3.0", available: true, checkedAt: 1_700_000_001_000))
    }

    @Test func offerIsMadeOnlyForANewerReleaseTheDaemonReportsAsAvailable() throws {
        let newer = try Self.info(
            update: #"{"current": "0.2.0", "latest": "0.3.0", "available": true, "checked_at": 1}"#)
        #expect(DaemonUpdateOffer.offer(for: newer)?.latest == "0.3.0")

        let notAvailable = try Self.info(
            update: #"{"current": "0.2.0", "latest": "0.3.0", "available": false, "checked_at": 1}"#)
        #expect(DaemonUpdateOffer.offer(for: notAvailable) == nil)

        // The daemon's flag says available, but the version is not newer than the daemon's own: nothing to offer.
        let older = try Self.info(
            update: #"{"current": "0.2.0", "latest": "0.1.9", "available": true, "checked_at": 1}"#)
        #expect(DaemonUpdateOffer.offer(for: older) == nil)

        let unparsable = try Self.info(
            update: #"{"current": "0.2.0", "latest": "nightly", "available": true, "checked_at": 1}"#)
        #expect(DaemonUpdateOffer.offer(for: unparsable) == nil)
    }

    @Test func noOfferWithoutInfo() {
        #expect(DaemonUpdateOffer.offer(for: nil) == nil)
    }

    @Test func appliedWhenTheDaemonReportsTheTargetVersion() throws {
        let info = try Self.info(update: "null", version: "0.3.0")
        #expect(DaemonUpdateOffer.isApplied(info, target: "0.3.0"))
        #expect(!DaemonUpdateOffer.isApplied(info, target: "0.4.0"))
        #expect(!DaemonUpdateOffer.isApplied(nil, target: "0.3.0"))
    }

    @Test func updateApplyReplyDecodes() throws {
        let reply = try RPCClient.decoder.decode(
            DaemonUpdateResult.self, from: Data(#"{"ok": true, "restarting": false}"#.utf8))
        #expect(reply == DaemonUpdateResult(ok: true, restarting: false))
    }
}
