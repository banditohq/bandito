import Foundation

extension ServerModel {
    /// The events after `seq`, read from the server and not applied to this model: what the background check shows as
    /// notices (`events.since`). Throws when the server cannot be reached.
    public func eventsSince(_ seq: Int64, limit: Int = 200) async throws -> [Event] {
        struct Since: Encodable {
            var after: Int64
            var limit: Int
        }
        return try await rpc().call("events.since", Since(after: seq, limit: limit), as: [Event].self)
    }
}
