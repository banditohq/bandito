@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@Suite struct RemoteDaemonUpdateRulesTests {
    typealias Rules = RemoteDaemonUpdateRules

    /// A `daemon.info` reply as the daemon sends it. `update` is the raw JSON of the field.
    static func info(
        version: String = "0.1.5", features: [String] = ["host", "update"], update: String = "null",
        safeMode: Bool = false
    ) throws -> DaemonInfo {
        let list = features.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
            {"version": "\(version)", "hostname": "box", "os": "linux", "arch": "x86_64",
             "started_at": 1700000000000, "last_seq": 7, "features": [\(list)], "update": \(update),
             "safe_mode": \(safeMode)}
            """
        return try RPCClient.decoder.decode(DaemonInfo.self, from: Data(json.utf8))
    }

    static func found(_ available: Bool, latest: String? = "0.1.9") -> DaemonUpdateCheck {
        DaemonUpdateCheck(current: "0.1.5", latest: latest, available: available)
    }

    static let infoOffer = DaemonUpdate(current: "0.1.5", latest: "0.1.9", available: true, checkedAt: 1)
    static let checkOffer = DaemonUpdate(current: "0.1.5", latest: "0.1.9", available: true, checkedAt: 99)

    @Test func offerFromTheCardIsShownWhateverElseIsKnown() throws {
        let info = try Self.info(update: #"{"current": "0.1.5", "latest": "0.1.9", "available": true, "checked_at": 1}"#)
        let choice = Rules.choice(info: info, connected: true, offer: Self.infoOffer, check: nil, checkAsked: true)
        #expect(choice == .offer(Self.infoOffer))
    }

    @Test func offerFromTheCheckIsShownWithoutAnInfoOffer() throws {
        let info = try Self.info()
        let choice = Rules.choice(
            info: info, connected: true, offer: Self.checkOffer, check: Self.found(true), checkAsked: true)
        #expect(choice == .offer(Self.checkOffer))
    }

    @Test func checkNotAvailableSaysUpToDate() throws {
        let choice = Rules.choice(
            info: try Self.info(), connected: true, offer: nil, check: Self.found(false), checkAsked: true)
        #expect(choice == .upToDate)
    }

    @Test func checkNotNewerThanTheDaemonSaysUpToDate() throws {
        // The daemon already runs the release the check names (it was updated meanwhile).
        let choice = Rules.choice(
            info: try Self.info(version: "0.1.9"), connected: true, offer: nil,
            check: Self.found(true, latest: "0.1.9"), checkAsked: true)
        #expect(choice == .upToDate)
    }

    @Test func availableCheckWithAnUnreadableVersionFallsBackToGitHub() throws {
        let choice = Rules.choice(
            info: try Self.info(), connected: true, offer: nil, check: Self.found(true, latest: "nightly"),
            checkAsked: true)
        #expect(choice == .releaseOnly)
    }

    @Test func aFailedCheckIsTheSameAsNoFeature() throws {
        let choice = Rules.choice(info: try Self.info(), connected: true, offer: nil, check: nil, checkAsked: true)
        #expect(choice == .releaseOnly)
    }

    @Test func withoutTheUpdateFeatureOnlyTheGitHubLineRemains() throws {
        let info = try Self.info(features: ["host"])
        let choice = Rules.choice(
            info: info, connected: true, offer: nil, check: Self.found(true), checkAsked: true)
        #expect(choice == .releaseOnly)
    }

    @Test func offlineServerIsNotAskedAndShowsOnlyTheGitHubLine() throws {
        let choice = Rules.choice(
            info: try Self.info(), connected: false, offer: nil, check: Self.found(true), checkAsked: true)
        #expect(choice == .releaseOnly)
    }

    @Test func safeModeShowsOnlyTheGitHubLine() throws {
        let choice = Rules.choice(
            info: try Self.info(safeMode: true), connected: true, offer: nil, check: nil, checkAsked: false)
        #expect(choice == .releaseOnly)
    }

    @Test func checkInFlightShowsChecking() throws {
        let choice = Rules.choice(info: try Self.info(), connected: true, offer: nil, check: nil, checkAsked: false)
        #expect(choice == .checking)
    }

    @Test func noInfoYetShowsOnlyTheGitHubLine() {
        let choice = Rules.choice(info: nil, connected: true, offer: nil, check: nil, checkAsked: false)
        #expect(choice == .releaseOnly)
    }
}
