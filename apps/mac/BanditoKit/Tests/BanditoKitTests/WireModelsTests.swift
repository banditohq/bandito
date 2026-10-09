import Foundation
import Testing

@testable import BanditoKit

/// Decoding of the wire models for files, terminals, changes, host, secrets, and plans.
/// The JSON samples follow docs/ARCHITECTURE.md and the daemon's serializers.
@Suite struct WireModelsTests {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: files

    @Test func fsEntryDecodesAndUnknownKindFallsBack() throws {
        let e = try decode(
            FsEntry.self,
            #"{"name":"a.md","path":"/w/a.md","kind":"file","size":12,"modified_ms":99,"hidden":false,"readonly":true,"symlink_target":null,"ext":"md"}"#)
        #expect(e.kind == .file)
        #expect(e.size == 12)
        #expect(e.modifiedMs == 99)
        #expect(e.readonly)
        #expect(e.ext == "md")
        #expect(e.symlinkTarget == nil)

        let odd = try decode(
            FsEntry.self,
            #"{"name":"x","path":"/w/x","kind":"socket","size":0,"modified_ms":1,"hidden":true,"readonly":false}"#)
        #expect(odd.kind == .other)
        #expect(odd.ext == nil)
        #expect(odd.hidden)
    }

    @Test func fsEntryKindCoversTheDaemonValues() throws {
        for (raw, kind) in [("file", FsEntryKind.file), ("dir", .dir), ("symlink", .symlink), ("other", .other)] {
            let e = try decode(
                FsEntry.self,
                #"{"name":"n","path":"/n","kind":"\#(raw)","size":0,"modified_ms":0,"hidden":false,"readonly":false}"#)
            #expect(e.kind == kind)
        }
    }

    @Test func fsListingDecodes() throws {
        let l = try decode(
            FsListing.self,
            #"{"path":"/w","parent":"/","entries":[{"name":"d","path":"/w/d","kind":"dir","size":0,"modified_ms":5,"hidden":false,"readonly":false}],"truncated":true,"skipped":2}"#)
        #expect(l.path == "/w")
        #expect(l.parent == "/")
        #expect(l.entries.map(\.kind) == [.dir])
        #expect(l.truncated)
        #expect(l.skipped == 2)
    }

    @Test func textFileDecodes() throws {
        let t = try decode(
            TextFile.self,
            #"{"path":"/w/a.md","content":"hi there","etag":"12-99","size":4,"modified_ms":99,"readonly":false}"#)
        #expect(t.content == "hi there")
        #expect(t.etag == "12-99")
        #expect(t.size == 4)
        #expect(t.modifiedMs == 99)
        #expect(!t.readonly)
    }

    @Test func projectHintDecodes() throws {
        let p = try decode(
            ProjectHint.self, #"{"path":"/w/p","name":"p","is_git":true,"modified_ms":5}"#)
        #expect(p.isGit)
        #expect(p.name == "p")
        #expect(p.modifiedMs == 5)
    }

    // MARK: terminals

    @Test func termInfoRunningAndExited() throws {
        let running = try decode(
            TermInfo.self,
            #"{"id":"t1","title":"sh","cwd":"/w","command":["/bin/zsh","-l"],"pid":4242,"cols":80,"rows":24,"created_at":10,"state":{"state":"running"},"offset":512}"#)
        #expect(running.command == ["/bin/zsh", "-l"])
        #expect(running.pid == 4242)
        #expect(running.state == .running)
        #expect(running.offset == 512)
        #expect(running.createdAt == 10)

        let exited = try decode(
            TermInfo.self,
            #"{"id":"t2","title":"x","cwd":"/w","command":["false"],"pid":1,"cols":80,"rows":24,"created_at":11,"state":{"state":"exited","code":3,"signal":null},"offset":0}"#)
        #expect(exited.state == .exited(code: 3, signal: nil))

        let signalled = try decode(
            TermInfo.self,
            #"{"id":"t3","title":"x","cwd":"/w","command":["sleep"],"pid":1,"cols":80,"rows":24,"created_at":11,"state":{"state":"exited","code":null,"signal":9},"offset":0}"#)
        #expect(signalled.state == .exited(code: nil, signal: 9))
    }

    @Test func unknownTermStateFallsBackToRunning() throws {
        let state = try decode(TermState.self, #"{"state":"hibernating"}"#)
        #expect(state == .running)
    }

    // MARK: changes

    @Test func checkpointDecodesAndUnknownKindFallsBack() throws {
        let c = try decode(
            Checkpoint.self,
            #"{"id":"c1","sha":"abc123","label":"start","kind":"before","turn_id":"turn-1","created_at":100}"#)
        #expect(c.kind == .before)
        #expect(c.turnId == "turn-1")
        #expect(c.sha == "abc123")
        #expect(c.createdAt == 100)

        let restore = try decode(
            Checkpoint.self,
            #"{"id":"c2","sha":"def","label":"undo","kind":"restore","turn_id":null,"created_at":101}"#)
        #expect(restore.kind == .restore)
        #expect(restore.turnId == nil)

        let odd = try decode(
            Checkpoint.self, #"{"id":"c3","sha":"x","label":"","kind":"mystery","turn_id":null,"created_at":1}"#)
        #expect(odd.kind == .after)
    }

    @Test func changesDiffAndFileChangeDecode() throws {
        let d = try decode(
            ChangesDiff.self,
            #"{"from":"c1","to":null,"files":[{"path":"src/a.rs","status":"renamed","from":"src/old.rs","additions":3,"deletions":null},{"path":"b.txt","status":"added","additions":1,"deletions":0}]}"#)
        #expect(d.from == "c1")
        #expect(d.to == nil)
        #expect(d.files.count == 2)
        #expect(d.files[0].status == .renamed)
        #expect(d.files[0].from == "src/old.rs")
        #expect(d.files[0].additions == 3)
        #expect(d.files[0].deletions == nil)
        #expect(d.files[1].status == .added)
        #expect(d.files[1].from == nil)

        let odd = try decode(
            FileChange.self, #"{"path":"z","status":"copied","additions":null,"deletions":null}"#)
        #expect(odd.status == .modified)
    }

    // MARK: host

    @Test func hostStatsDecodes() throws {
        let s = try decode(
            HostStats.self,
            #"{"os":"macos 26.0","kernel":"25.6.0","arch":"arm64","hostname":"mini","cpus":10,"cpu_percent":12.5,"load":[1.5,1.25,1.0],"mem_total":17179869184,"mem_used":8589934592,"swap_total":0,"swap_used":0,"disks":[{"mount":"/","total":500,"used":200}],"net_rx_bps":1024,"net_tx_bps":2048,"net_supported":true,"uptime_s":3600}"#)
        #expect(s.hostname == "mini")
        #expect(s.cpus == 10)
        #expect(s.cpuPercent == 12.5)
        #expect(s.load == [1.5, 1.25, 1.0])
        #expect(s.memTotal == 17_179_869_184)
        #expect(s.memUsed == 8_589_934_592)
        #expect(s.swapTotal == 0)
        #expect(s.disks == [HostDisk(mount: "/", total: 500, used: 200)])
        #expect(s.netRxBps == 1024)
        #expect(s.netTxBps == 2048)
        #expect(s.netSupported)
        #expect(s.uptimeS == 3600)

        // Without network counters the daemon sends net_supported false, with zeros.
        let noNet = try decode(
            HostStats.self,
            #"{"os":"macos","kernel":"25","arch":"arm64","hostname":"mini","cpus":8,"cpu_percent":0.0,"load":[0.0,0.0,0.0],"mem_total":1,"mem_used":0,"swap_total":0,"swap_used":0,"disks":[],"net_rx_bps":0,"net_tx_bps":0,"net_supported":false,"uptime_s":1}"#)
        #expect(!noNet.netSupported)
    }

    @Test func daemonOwnerHasNoIdAndUnknownKindFallsBack() throws {
        // Shapes from daemon/src/host.rs: the daemon's own process has `id: null`; a kind this app
        // doesn't know must not decode as an agent.
        let p = try decode(
            HostProcesses.self,
            #"{"supported":true,"owners":[{"owner":{"kind":"daemon","id":null},"cpu_percent":0.5,"rss_bytes":10,"processes":[{"pid":7,"name":"bandito","cmd":"bandito daemon"}]},{"owner":{"kind":"robot","id":"x"},"cpu_percent":0.0,"rss_bytes":0,"processes":[]}]}"#)
        #expect(p.owners[0].owner == ProcessOwnerRef(kind: .daemon, id: nil))
        #expect(p.owners[1].owner.kind == .daemon)
        #expect(p.owners[1].owner.id == "x")
    }

    @Test func portOwnerIsOptionalAndPidMayBeNull() throws {
        let p = try decode(
            HostPorts.self,
            #"{"supported":true,"ports":[{"port":5173,"addr":"*","pid":99,"process":"node","owner":{"kind":"terminal","id":"t9"}}]}"#)
        #expect(p.ports[0].addr == "*")
        #expect(p.ports[0].owner == ProcessOwnerRef(kind: .terminal, id: "t9"))
    }

    @Test func historyRangeHasTheDaemonNames() {
        #expect(HostHistoryRange.hour.rawValue == "1h")
        #expect(HostHistoryRange.day.rawValue == "24h")
    }

    @Test func hostHistoryPointsDecode() throws {
        let h = try decode(
            HostHistory.self,
            #"{"points":[{"t":1000,"cpu":12.5,"mem_used":100,"net_rx_bps":5,"net_tx_bps":6}]}"#)
        #expect(h.points == [HostPoint(t: 1000, cpu: 12.5, memUsed: 100, netRxBps: 5, netTxBps: 6)])
    }

    @Test func hostProcessesDecode() throws {
        let p = try decode(
            HostProcesses.self,
            #"{"supported":true,"owners":[{"owner":{"kind":"agent","id":"a1"},"cpu_percent":3.5,"rss_bytes":1024,"processes":[{"pid":1,"name":"node","cmd":"node x.js"}]}]}"#)
        #expect(p.supported)
        #expect(p.owners.count == 1)
        #expect(p.owners[0].owner == ProcessOwnerRef(kind: .agent, id: "a1"))
        #expect(p.owners[0].cpuPercent == 3.5)
        #expect(p.owners[0].rssBytes == 1024)
        #expect(p.owners[0].processes == [HostProcess(pid: 1, name: "node", cmd: "node x.js")])

        let unsupported = try decode(HostProcesses.self, #"{"supported":false,"owners":[]}"#)
        #expect(!unsupported.supported)
        #expect(unsupported.owners.isEmpty)
    }

    @Test func listeningPortsDecodeWithOptionalOwner() throws {
        let p = try decode(
            HostPorts.self,
            #"{"supported":true,"ports":[{"port":3000,"addr":"127.0.0.1","pid":12,"process":"node","owner":{"kind":"agent","id":"a1"}},{"port":22,"addr":"0.0.0.0","pid":null,"process":null}]}"#)
        #expect(p.ports.count == 2)
        #expect(p.ports[0].port == 3000)
        #expect(p.ports[0].pid == 12)
        #expect(p.ports[0].owner == ProcessOwnerRef(kind: .agent, id: "a1"))
        #expect(p.ports[1].pid == nil)
        #expect(p.ports[1].process == nil)
        #expect(p.ports[1].owner == nil)
    }

    // MARK: secrets

    @Test func secretInfoDecodes() throws {
        let s = try decode(
            SecretInfo.self, #"{"name":"OPENAI_API_KEY","tail":"wxyz","agents":["*"],"updated_at":7}"#)
        #expect(s.name == "OPENAI_API_KEY")
        #expect(s.tail == "wxyz")
        #expect(s.agents == ["*"])
        #expect(s.updatedAt == 7)
    }

    // MARK: plan

    @Test func usageEntryDecodesPlan() throws {
        let e = try decode(
            UsageEntry.self,
            #"{"runtime":"claude","windows":[],"updated_at":1,"plan":{"id":"max_20x","label":"Max ×20"}}"#)
        #expect(e.plan == Plan(id: "max_20x", label: "Max ×20"))
    }

    @Test func usageEntryWithoutPlanHasNilPlan() throws {
        let e = try decode(UsageEntry.self, #"{"runtime":"codex","windows":[],"updated_at":1,"plan":null}"#)
        #expect(e.plan == nil)
        let old = try decode(UsageEntry.self, #"{"runtime":"codex","windows":[],"updated_at":1}"#)
        #expect(old.plan == nil)
    }
}
