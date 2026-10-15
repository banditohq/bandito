import Foundation

// Read marks between the owner's devices (docs/ARCHITECTURE.md#read-marks). A device tells the daemon the seq it read a
// chat to (`messages.read`), the daemon tells the other devices (`read_mark`), and `agents.list` carries the mark too.
// The sending itself (once per agent per second, off for an older daemon) is `ReadMarkSync`.

extension ServerModel {
    /// `messages.read`: this device read the agent's chat to `seq`. The daemon keeps the newer of its mark and `seq`
    /// and answers with it; a newer mark from another device is applied here (it is not sent back).
    func sendReadMark(agentID: String, seq: Int64) async throws {
        struct Params: Encodable {
            var agentId: String
            var seq: Int64
        }
        struct Reply: Decodable { var seq: Int64 }
        // A daemon that reports its features without read marks gets no call at all.
        if let info, !info.supports("read_marks") {
            throw RPCError(code: RPCError.methodNotFound, message: "the daemon has no read marks")
        }
        let reply = try await rpc().call("messages.read", Params(agentId: agentID, seq: seq), as: Reply.self)
        // The daemon keeps the newer of its mark and `seq`: a newer one from another device is applied here.
        receivedReadMark(agentID: agentID, seq: reply.seq)
    }
}
