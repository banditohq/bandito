import Foundation
import Testing

@testable import BanditoKit

@Suite struct PrimaryDiskTests {
    private func stats(disks: [HostDisk]) -> HostStats {
        HostStats(
            os: "macOS", kernel: "25.6.0", arch: "arm64", hostname: "host", cpus: 8, cpuPercent: 10, load: [0, 0, 0],
            memTotal: 1, memUsed: 0, swapTotal: 0, swapUsed: 0, disks: disks, netRxBps: 0, netTxBps: 0,
            netSupported: true, uptimeS: 1)
    }

    @Test func rootIsTheSharedDisk() {
        let root = HostDisk(mount: "/", total: 1000, used: 400)
        let home = HostDisk(mount: "/Users/me", total: 1000, used: 700)
        #expect(stats(disks: [home, root]).primaryDisk == root)
        #expect(stats(disks: [root, home]).primaryDisk == root)
    }

    @Test func firstEntryWhenRootIsNotListed() {
        let data = HostDisk(mount: "/data", total: 500, used: 100)
        #expect(stats(disks: [data]).primaryDisk == data)
    }

    @Test func noDisksMeansNoDisk() {
        #expect(stats(disks: []).primaryDisk == nil)
    }
}
