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

    @Test func restoreReplySaysTheDaemonRestarts() throws {
        let reply = try RPCClient.decoder.decode(BackupRestoreReply.self, from: Data(#"{"restarting":true}"#.utf8))
        #expect(reply.restarting)
    }
}
