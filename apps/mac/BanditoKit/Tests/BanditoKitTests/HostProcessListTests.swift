import Foundation
import Testing

@testable import BanditoKit

@Suite struct HostProcessListTests {
    private func top(_ pid: Int, _ name: String, memory: Int64, cpu: Double = 0, own: Bool = true, safe: Bool = true) -> HostTopProcess {
        HostTopProcess(pid: pid, name: name, rssBytes: memory, cpuPercent: cpu, own: own, ownSafe: safe)
    }

    private func owner(_ kind: ProcessOwnerKind, _ id: String?, pids: [Int]) -> ProcessOwner {
        ProcessOwner(
            owner: ProcessOwnerRef(kind: kind, id: id), cpuPercent: 0, rssBytes: 0,
            processes: pids.map { HostProcess(pid: $0, name: "p\($0)", cmd: "p\($0)") })
    }

    @Test func memoryRowsAreBiggestFirstAndTiesGoByPid() {
        let rows = HostProcessList.rows(
            top: [top(9, "a", memory: 100), top(3, "b", memory: 300), top(7, "c", memory: 100)],
            owners: [], sort: .memory)
        #expect(rows.map(\.pid) == [3, 7, 9])
    }

    @Test func cpuRowsAreBusiestFirst() {
        let rows = HostProcessList.rows(
            top: [top(1, "a", memory: 1, cpu: 2.5), top(2, "b", memory: 9, cpu: 40)],
            owners: [], sort: .cpu)
        #expect(rows.map(\.pid) == [2, 1])
    }

    @Test func anOrdinaryOwnProcessCanBeStopped() {
        let rows = HostProcessList.rows(top: [top(30, "Preview", memory: 1)], owners: [], sort: .memory)
        #expect(rows.first?.canStop == true)
        #expect(rows.first?.isAgent == false)
    }

    @Test func aProcessThatTheDaemonDoesNotCallSafeIsNotStopped() {
        // A tree the daemon could not read, or a daemon that does not send the flag: no button.
        let rows = HostProcessList.rows(top: [top(31, "zsh", memory: 1, safe: false)], owners: [], sort: .memory)
        #expect(rows.first?.canStop == false)
    }

    @Test func aListShowsItsSortOrderAndAtMostTheLimit() {
        let many = (1...20).map { top($0, "p\($0)", memory: Int64($0) * 10, cpu: Double(21 - $0)) }
        let byMemory = HostProcessList.rows(top: many, owners: [], sort: .memory)
        #expect(byMemory.count == HostProcessList.limit)
        #expect(byMemory.first?.pid == 20)
        let byCPU = HostProcessList.rows(top: many, owners: [], sort: .cpu)
        #expect(byCPU.count == HostProcessList.limit)
        #expect(byCPU.first?.pid == 1, "busiest first, whatever its memory")
    }

    @Test func anAgentsProcessIsMarkedAndNotStoppedHere() {
        let rows = HostProcessList.rows(
            top: [top(20, "node", memory: 1)],
            owners: [owner(.agent, "a1", pids: [20])], sort: .memory)
        #expect(rows.first?.isAgent == true)
        #expect(rows.first?.owner == ProcessOwnerRef(kind: .agent, id: "a1"))
        #expect(rows.first?.canStop == false)
    }

    @Test func aTerminalsAndTheDaemonsProcessesAreNotStopped() {
        let rows = HostProcessList.rows(
            top: [top(21, "zsh", memory: 2), top(22, "bandito", memory: 1)],
            owners: [owner(.terminal, "t1", pids: [21]), owner(.daemon, nil, pids: [22])], sort: .memory)
        #expect(rows.allSatisfy { !$0.canStop })
        #expect(rows.first { $0.pid == 21 }?.owner?.kind == .terminal)
    }

    @Test func otherUsersProcessesAndPidOneAreNotStopped() {
        #expect(!HostProcessList.canStop(pid: 40, ownSafe: false, owner: nil))
        #expect(!HostProcessList.canStop(pid: 1, ownSafe: true, owner: nil))
        #expect(HostProcessList.canStop(pid: 2, ownSafe: true, owner: nil))
    }

    @Test func statsDecodeTheTopProcessesAndOldDaemonsLeaveThemOut() throws {
        let with = try RPCClient.decoder.decode(
            HostStats.self, from: Data(
                #"{"os":"macos","kernel":"25","arch":"arm64","hostname":"mini","cpus":8,"cpu_percent":5.0,"load":[0.1,0.2,0.3],"mem_total":10,"mem_used":5,"swap_total":0,"swap_used":0,"disks":[],"net_rx_bps":0,"net_tx_bps":0,"net_supported":true,"uptime_s":60,"top_processes":[{"pid":4242,"name":"Google Chrome","rss_bytes":204800,"cpu_percent":3.5,"own":true}]}"#
                    .utf8))
        #expect(with.topProcesses == [HostTopProcess(pid: 4242, name: "Google Chrome", rssBytes: 204_800, cpuPercent: 3.5, own: true, ownSafe: false)])
        let without = try RPCClient.decoder.decode(
            HostStats.self, from: Data(
                #"{"os":"macos","kernel":"25","arch":"arm64","hostname":"mini","cpus":8,"cpu_percent":5.0,"load":[0.1,0.2,0.3],"mem_total":10,"mem_used":5,"swap_total":0,"swap_used":0,"disks":[],"net_rx_bps":0,"net_tx_bps":0,"net_supported":true,"uptime_s":60}"#
                    .utf8))
        #expect(without.topProcesses == nil)
    }

    @Test func aProcessWithOwnSafeDecodesIt() throws {
        let p = try RPCClient.decoder.decode(
            HostTopProcess.self, from: Data(#"{"pid":7,"name":"sleep","rss_bytes":1,"cpu_percent":0,"own":true,"own_safe":true}"#.utf8))
        #expect(p.ownSafe)
    }

    @Test func killReplyDecodes() throws {
        let reply = try RPCClient.decoder.decode(HostKillReply.self, from: Data(#"{"ok":true,"killed":false}"#.utf8))
        #expect(reply == HostKillReply(ok: true, killed: false))
    }

    private func entry(_ pid: Int, _ name: String, memory: Int64, cpu: Double = 0, owner: ProcessOwnerRef? = nil) -> HostProcessEntry {
        HostProcessEntry(pid: pid, name: name, rssBytes: memory, cpuPercent: cpu, owner: owner, canStop: owner == nil)
    }

    @Test func appNameCutsHelperSuffixes() {
        #expect(HostProcessList.appName("Google Chrome Helper (Renderer)") == "Google Chrome")
        #expect(HostProcessList.appName("Google Chrome Helper (GPU)") == "Google Chrome")
        #expect(HostProcessList.appName("Slack Helper") == "Slack")
        #expect(HostProcessList.appName("Foo (Renderer)") == "Foo")
        #expect(HostProcessList.appName("Google Chrome") == "Google Chrome")
        #expect(HostProcessList.appName("com.apple.Virtualization.VirtualMachine") == "com.apple.Virtualization.VirtualMachine")
        #expect(HostProcessList.appName("Helper") == "Helper")
    }

    @Test func chromeHelpersMergeAndSumUp() {
        let rows = [
            entry(1, "Google Chrome Helper (Renderer)", memory: 300),
            entry(2, "zsh", memory: 500),
            entry(3, "Google Chrome Helper (Renderer)", memory: 200),
            entry(4, "Google Chrome", memory: 100),
        ]
        let groups = HostProcessList.groups(rows, sort: .memory)
        #expect(groups.map(\.appName) == ["Google Chrome", "zsh"])
        #expect(groups[0].rssBytes == 600)
        #expect(groups[0].members.map(\.pid) == [1, 3, 4])
        #expect(groups[0].isGroup && !groups[1].isGroup)
    }

    @Test func agentProcessesAreNotMergedWithOthers() {
        let agent = ProcessOwnerRef(kind: .agent, id: "a1")
        let other = ProcessOwnerRef(kind: .agent, id: "a2")
        let rows = [
            entry(1, "claude", memory: 100),
            entry(2, "claude", memory: 400, owner: agent),
            entry(3, "claude", memory: 300, owner: other),
            entry(4, "claude", memory: 50, owner: agent),
        ]
        let groups = HostProcessList.groups(rows, sort: .memory)
        #expect(groups.count == 3)
        #expect(groups[0].owner == agent && groups[0].rssBytes == 450 && groups[0].members.count == 2)
        #expect(groups[1].owner == other)
        #expect(groups[2].owner == nil && groups[2].rssBytes == 100)
    }

    @Test func groupsAreSortedBySumForCPU() {
        let rows = [
            entry(1, "A Helper", memory: 1, cpu: 10), entry(2, "A Helper (GPU)", memory: 1, cpu: 15),
            entry(3, "B", memory: 1, cpu: 20),
        ]
        let groups = HostProcessList.groups(rows, sort: .cpu)
        #expect(groups.map(\.appName) == ["A", "B"])
        #expect(groups[0].cpuPercent == 25)
    }

    @Test func statsDecodeTheAppGroupsAndOldDaemonsLeaveThemOut() throws {
        let with = try RPCClient.decoder.decode(
            HostStats.self, from: Data(
                #"{"os":"macos","kernel":"25","arch":"arm64","hostname":"mini","cpus":8,"cpu_percent":5.0,"load":[0.1,0.2,0.3],"mem_total":10,"mem_used":5,"swap_total":0,"swap_used":0,"disks":[],"net_rx_bps":0,"net_tx_bps":0,"net_supported":true,"uptime_s":60,"app_groups":[{"name":"Google Chrome","cpu_percent":12.5,"memory_bytes":900,"process_count":40,"top_pids":[11,12,13]}]}"#
                    .utf8))
        #expect(with.appGroups == [HostAppGroup(name: "Google Chrome", cpuPercent: 12.5, memoryBytes: 900, processCount: 40, topPids: [11, 12, 13])])
        let without = try RPCClient.decoder.decode(
            HostStats.self, from: Data(
                #"{"os":"macos","kernel":"25","arch":"arm64","hostname":"mini","cpus":8,"cpu_percent":5.0,"load":[0.1,0.2,0.3],"mem_total":10,"mem_used":5,"swap_total":0,"swap_used":0,"disks":[],"net_rx_bps":0,"net_tx_bps":0,"net_supported":true,"uptime_s":60}"#
                    .utf8))
        #expect(without.appGroups == nil)
    }

    @Test func appGroupsUseTheDaemonsSumsAndListTheProcessesTheListKnows() {
        // The daemon counted 40 Chrome processes and names three; the list knows pids 11 and 12, not 99.
        let apps = [
            HostAppGroup(name: "Google Chrome", cpuPercent: 12.5, memoryBytes: 900, processCount: 40, topPids: [11, 99, 12]),
            HostAppGroup(name: "Preview", cpuPercent: 0, memoryBytes: 50, processCount: 1, topPids: [30]),
        ]
        let rows = [
            entry(11, "Google Chrome Helper", memory: 500, cpu: 3), entry(12, "Google Chrome", memory: 100, cpu: 1),
            entry(30, "Preview", memory: 50, cpu: 0),
        ]
        let groups = HostProcessList.appGroups(apps, rows: rows, sort: .memory)
        #expect(groups.map(\.appName) == ["Google Chrome", "Preview"])
        #expect(groups[0].rssBytes == 900 && groups[0].cpuPercent == 12.5)
        #expect(groups[0].processCount == 40 && groups[0].isGroup)
        #expect(groups[0].members.map(\.pid) == [11, 12])
        #expect(groups[1].isGroup == false && groups[1].members.map(\.pid) == [30])
        // An app whose processes the list does not name is still shown with its sums, and has nothing to expand.
        let unknown = HostProcessList.appGroups(
            [HostAppGroup(name: "Dock", cpuPercent: 1, memoryBytes: 7, processCount: 3, topPids: [77])],
            rows: rows, sort: .cpu)
        #expect(unknown[0].members.isEmpty && unknown[0].processCount == 3 && unknown[0].rssBytes == 7)
    }
}
