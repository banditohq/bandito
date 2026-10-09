import Foundation

// What agents changed in their folders (docs/ARCHITECTURE.md#changes).

extension ServerModel {
    /// Checkpoints of an agent, newest first. `limit` is 1…200 (the daemon's default is 50).
    public func checkpoints(agentID: String, limit: Int? = nil) async throws -> [Checkpoint] {
        struct P: Encodable { var agentId: String; var limit: Int? }
        return try await rpc().call(
            "changes.checkpoints", P(agentId: agentID, limit: limit), as: [Checkpoint].self)
    }

    /// Files changed between two checkpoints. `from` defaults to the agent's last `before` checkpoint,
    /// `to` to the working folder as it is now.
    public func changesDiff(agentID: String, from: String? = nil, to: String? = nil) async throws -> ChangesDiff {
        struct P: Encodable { var agentId: String; var from: String?; var to: String? }
        return try await rpc().call(
            "changes.diff", P(agentId: agentID, from: from, to: to), as: ChangesDiff.self)
    }

    /// Unified diff (3 lines of context) of one file, cut at 512 KiB (`truncated`).
    public func changedFile(agentID: String, path: String, from: String? = nil, to: String? = nil) async throws
        -> (diff: String, truncated: Bool)
    {
        struct P: Encodable { var agentId: String; var path: String; var from: String?; var to: String? }
        struct Reply: Decodable { var diff: String; var truncated: Bool }
        let reply = try await rpc().call(
            "changes.file", P(agentId: agentID, path: path, from: from, to: to), as: Reply.self)
        return (reply.diff, reply.truncated)
    }

    /// Restores files (all of them when `paths` is nil) to a checkpoint. Returns the restored paths and
    /// the checkpoint that holds the state before the restore, which undoes it.
    public func restore(agentID: String, checkpointID: String, paths: [String]? = nil) async throws
        -> (restored: [String], undo: String)
    {
        struct P: Encodable { var agentId: String; var checkpointId: String; var paths: [String]? }
        struct Reply: Decodable { var restored: [String]; var undoCheckpointId: String }
        let reply = try await rpc().call(
            "changes.restore", P(agentId: agentID, checkpointId: checkpointID, paths: paths), as: Reply.self)
        return (reply.restored, reply.undoCheckpointId)
    }
}
