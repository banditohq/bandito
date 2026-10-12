@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The server settings page's rules: the ranges the controls keep to, the change that becomes a patch, the change that
/// is shown at once, and the report for support, which carries no address, token, host name or path.
@Suite struct ServerSettingsLogicTests {
    private static let current = ServerSettingValues(
        screenIdleMinutes: 30, maxRunningAgents: 0, backupEveryHours: 24, backupKeep: 14, autoUpdate: .notify,
        updateChannel: "stable", defaultApprovalMode: .risky)

    private static let daemonSample = #"""
    {"version":"0.1.10","hostname":"build-box.internal","os":"linux","arch":"x86_64","started_at":1,"last_seq":5,
     "features":["server_settings","backups","host"],"safe_mode":false,"safe_mode_error":"/home/ana/.bandito/bandito.db is locked"}
    """#

    private static let hostSample = #"""
    {"os":"Ubuntu 24.04","kernel":"6.8.0-45-generic","arch":"x86_64","hostname":"build-box.internal","cpus":8,
     "cpu_percent":12.5,"load":[0.1,0.2,0.3],"mem_total":17179869184,"mem_used":4294967296,"swap_total":0,"swap_used":0,
     "disks":[{"mount":"/","total":500000000000,"used":120000000000}],"net_rx_bps":0,"net_tx_bps":0,
     "net_supported":true,"uptime_s":90000}
    """#

    // MARK: Ranges and patches

    @Test func screenIdleRangeIsFiveToTwoHundredForty() {
        #expect(ServerSettingChange.screenIdleMinutes(5).patch == ServerSettingsPatch(screenIdleMinutes: 5))
        #expect(ServerSettingChange.screenIdleMinutes(240).patch == ServerSettingsPatch(screenIdleMinutes: 240))
        #expect(ServerSettingChange.screenIdleMinutes(4).patch == nil)
        #expect(ServerSettingChange.screenIdleMinutes(241).patch == nil)
    }

    @Test func maxRunningAgentsIsZeroForNoLimitOrOneToFifty() {
        for count in [0, 1, 50] {
            #expect(ServerSettingChange.maxRunningAgents(count).patch == ServerSettingsPatch(maxRunningAgents: count))
        }
        #expect(ServerSettingChange.maxRunningAgents(-1).patch == nil)
        #expect(ServerSettingChange.maxRunningAgents(51).patch == nil)
    }

    @Test func backupCadenceIsOneOfTheFiveDaemonValues() {
        for hours in [6, 12, 24, 48, 168] {
            #expect(ServerSettingChange.backupEveryHours(hours).patch == ServerSettingsPatch(backupEveryHours: hours))
        }
        for hours in [1, 7, 72, 169] {
            #expect(ServerSettingChange.backupEveryHours(hours).patch == nil)
        }
    }

    @Test func backupKeepRangeIsThreeToSixty() {
        #expect(ServerSettingChange.backupKeep(3).patch == ServerSettingsPatch(backupKeep: 3))
        #expect(ServerSettingChange.backupKeep(60).patch == ServerSettingsPatch(backupKeep: 60))
        #expect(ServerSettingChange.backupKeep(2).patch == nil)
        #expect(ServerSettingChange.backupKeep(61).patch == nil)
    }

    @Test func enumChangesBecomeOneFieldPatches() {
        #expect(ServerSettingChange.autoUpdate(.install).patch == ServerSettingsPatch(autoUpdate: .install))
        #expect(
            ServerSettingChange.defaultApprovalMode(.never).patch == ServerSettingsPatch(defaultApprovalMode: .never))
    }

    @Test func pickingTheValueAlreadySetSendsNothing() {
        #expect(!ServerSettingChange.screenIdleMinutes(30).differs(from: Self.current))
        #expect(ServerSettingChange.screenIdleMinutes(31).differs(from: Self.current))
        #expect(!ServerSettingChange.autoUpdate(.notify).differs(from: Self.current))
        #expect(ServerSettingChange.defaultApprovalMode(.always).differs(from: Self.current))
        #expect(!ServerSettingChange.maxRunningAgents(0).differs(from: Self.current))
        #expect(!ServerSettingChange.backupEveryHours(24).differs(from: Self.current))
        #expect(!ServerSettingChange.backupKeep(14).differs(from: Self.current))
    }

    @Test func appliedShowsTheChangeAndKeepsTheRest() {
        let next = ServerSettingChange.maxRunningAgents(4).applied(to: Self.current)
        #expect(next.maxRunningAgents == 4)
        #expect(next.screenIdleMinutes == 30)
        #expect(next.defaultApprovalMode == .risky)
    }

    // MARK: Report for support

    private static func report(daemonJSON: String? = daemonSample, hostJSON: String? = hostSample) throws -> ServerSupportReport {
        let daemon = try daemonJSON.map { try RPCClient.decoder.decode(DaemonInfo.self, from: Data($0.utf8)) }
        let host = try hostJSON.map { try RPCClient.decoder.decode(HostStats.self, from: Data($0.utf8)) }
        return ServerSupportReport.make(
            appVersion: "0.1.11", appBuild: "1100", macOS: "15.1.0", macArchitecture: "arm64", daemon: daemon, host: host)
    }

    @Test func reportNamesVersionsSystemAndSortedFeatures() throws {
        let text = try Self.report().text
        #expect(text.contains("Bandito for Mac: 0.1.11 (build 1100)"))
        #expect(text.contains("Mac: macOS 15.1.0, arm64"))
        #expect(text.contains("Daemon: 0.1.10"))
        #expect(text.contains("Server system: linux x86_64, kernel 6.8.0-45-generic"))
        #expect(text.contains("Safe mode: no"))
        #expect(text.contains("Features: backups, host, server_settings"))
    }

    @Test func reportCarriesNoAddressTokenHostNameOrPath() throws {
        let text = try Self.report().text
        #expect(!text.contains("build-box"))
        #expect(!text.contains("/home/"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("wss://"))
        #expect(!text.contains("ssh"))
        #expect(!text.lowercased().contains("token"))
        // The safe-mode reason names a path on the server, so it stays out with the rest of the paths.
        #expect(!text.contains("bandito.db"))
    }

    @Test func reportSaysUnknownWhenTheServerDidNotAnswer() throws {
        let text = try Self.report(daemonJSON: nil, hostJSON: nil).text
        #expect(text.contains("Daemon: unknown"))
        #expect(text.contains("Server system: unknown, kernel unknown"))
        #expect(text.contains("Features: none"))
    }
}
