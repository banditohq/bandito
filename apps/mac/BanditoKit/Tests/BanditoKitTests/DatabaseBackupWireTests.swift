import Foundation
import Testing

@testable import BanditoKit

/// The wire shapes of `backups.list`, `backups.create` and `backups.restore`, read with the app's decoder
/// (snake_case keys become camelCase).
@Suite struct DatabaseBackupWireTests {
    @Test func listEntryReadsEveryField() throws {
        let raw = #"[{"name":"bandito-20270115-080000-start.db","size":4096,"created_at_ms":1800000000000,"reason":"start"}]"#
        let list = try RPCClient.decoder.decode([DatabaseBackup].self, from: Data(raw.utf8))
        #expect(list.count == 1)
        #expect(list[0].name == "bandito-20270115-080000-start.db")
        #expect(list[0].size == 4096)
        #expect(list[0].createdAtMs == 1_800_000_000_000)
        #expect(list[0].reason == "start")
        #expect(list[0].id == list[0].name)
        #expect(list[0].createdAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func emptyListDecodes() throws {
        let list = try RPCClient.decoder.decode([DatabaseBackup].self, from: Data("[]".utf8))
        #expect(list.isEmpty)
    }

    @Test func daemonInfoReadsTheLastRestore() throws {
        let raw = #"{"version":"0.1.6","hostname":"h","os":"macos","arch":"arm64","started_at":1,"last_seq":0,"last_restore":{"name":"bandito-20270115-080000-start.db","ok":false,"error":"no backup named x","at_ms":3}}"#
        let info = try RPCClient.decoder.decode(DaemonInfo.self, from: Data(raw.utf8))
        #expect(info.lastRestore == LastRestore(name: "bandito-20270115-080000-start.db", ok: false, error: "no backup named x", atMs: 3))
    }

    @Test func daemonInfoFromAnOlderDaemonHasNoLastRestore() throws {
        let raw = #"{"version":"0.1.5","hostname":"h","os":"macos","arch":"arm64","started_at":1,"last_seq":0}"#
        let info = try RPCClient.decoder.decode(DaemonInfo.self, from: Data(raw.utf8))
        #expect(info.lastRestore == nil)
    }

    @Test func restoreReplySaysTheDaemonRestarts() throws {
        let reply = try RPCClient.decoder.decode(BackupRestoreReply.self, from: Data(#"{"restarting":true}"#.utf8))
        #expect(reply.restarting)
        #expect(reply.id == nil, "an older daemon sends no id")
    }

    @Test func restoreReplyCarriesTheOperationId() throws {
        let reply = try RPCClient.decoder.decode(
            BackupRestoreReply.self, from: Data(#"{"restarting":true,"id":"0192-op"}"#.utf8))
        #expect(reply.id == "0192-op")
    }

    @Test func lastRestoreCarriesTheOperationId() throws {
        let raw = #"{"id":"0192-op","name":"bandito-20270115-080000-start.db","ok":true,"error":null,"at_ms":3}"#
        let record = try RPCClient.decoder.decode(LastRestore.self, from: Data(raw.utf8))
        #expect(record.id == "0192-op")
    }

    @Test func listReadsSetAsideDatabases() throws {
        let raw = #"[{"name":"replaced-20270115-080000.db","size":10,"created_at_ms":1800000000000,"reason":"replaced"},{"name":"broken-20270115-070000.db","size":5,"created_at_ms":1799996400000,"reason":"broken"}]"#
        let list = try RPCClient.decoder.decode([DatabaseBackup].self, from: Data(raw.utf8))
        #expect(list.map(\.reason) == ["replaced", "broken"])
    }

    @Test func daemonInfoReadsSafeMode() throws {
        let raw = #"{"version":"0.1.6","hostname":"h","os":"macos","arch":"arm64","started_at":1,"last_seq":0,"safe_mode":true,"safe_mode_error":"no way back"}"#
        let info = try RPCClient.decoder.decode(DaemonInfo.self, from: Data(raw.utf8))
        #expect(info.isSafeMode)
        #expect(info.safeModeError == "no way back")
        let older = #"{"version":"0.1.5","hostname":"h","os":"macos","arch":"arm64","started_at":1,"last_seq":0}"#
        #expect(try RPCClient.decoder.decode(DaemonInfo.self, from: Data(older.utf8)).isSafeMode == false)
    }
}
