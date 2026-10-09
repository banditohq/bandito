import Foundation
import Testing

@testable import BanditoKit

@Suite struct HostHealthTests {
    /// Builds the stats the daemon sends, with only the fields the health rule reads being interesting.
    func stats(memUsed: Int64, memTotal: Int64, disks: [(used: Int64, total: Int64)]) throws -> HostStats {
        let diskJSON = disks.enumerated().map { i, d in
            #"{"mount":"\#(i == 0 ? "/" : "/home")","total":\#(d.total),"used":\#(d.used)}"#
        }.joined(separator: ",")
        let json = """
            {"os":"Ubuntu 24.04","kernel":"6.8","arch":"x86_64","hostname":"vps","cpus":4,"cpu_percent":38,
             "load":[0.5,0.4,0.3],"mem_total":\(memTotal),"mem_used":\(memUsed),"swap_total":0,"swap_used":0,
             "disks":[\(diskJSON)],"net_rx_bps":100,"net_tx_bps":50,"net_supported":true,"uptime_s":60}
            """
        return try RPCClient.decoder.decode(HostStats.self, from: Data(json.utf8))
    }

    @Test func healthyServerHasNoWarnings() throws {
        let s = try stats(memUsed: 5, memTotal: 8, disks: [(used: 38, total: 160)])
        #expect(HostHealth.evaluate(s) == HostHealth(diskFull: false, memoryFull: false))
        #expect(HostHealth.evaluate(s).isOK)
    }

    @Test func diskAboveNinetyPercentWarns() throws {
        let s = try stats(memUsed: 1, memTotal: 8, disks: [(used: 91, total: 100)])
        let health = HostHealth.evaluate(s)
        #expect(health.diskFull)
        #expect(!health.memoryFull)
        #expect(!health.isOK)
    }

    @Test func exactlyNinetyPercentIsStillFine() throws {
        let disk = try stats(memUsed: 1, memTotal: 8, disks: [(used: 90, total: 100)])
        let mem = try stats(memUsed: 72, memTotal: 80, disks: [(used: 1, total: 100)])
        #expect(HostHealth.evaluate(disk).isOK)
        #expect(HostHealth.evaluate(mem).isOK)
    }

    @Test func memoryAboveNinetyPercentWarnsAndBothCanStack() throws {
        let s = try stats(memUsed: 74, memTotal: 80, disks: [(used: 95, total: 100)])
        let health = HostHealth.evaluate(s)
        #expect(health.memoryFull)
        #expect(health.diskFull)
    }

    @Test func secondDiskIsCheckedToo() throws {
        let s = try stats(memUsed: 1, memTotal: 8, disks: [(used: 10, total: 100), (used: 99, total: 100)])
        #expect(HostHealth.evaluate(s).diskFull)
    }

    @Test func zeroTotalDoesNotDivideByZero() throws {
        let s = try stats(memUsed: 0, memTotal: 0, disks: [(used: 0, total: 0)])
        #expect(HostHealth.evaluate(s).isOK)
    }
}
