import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoUI

/// A quiet turn ends without a notice and without a sound (docs/ARCHITECTURE.md#quiet-turns). A turn that is not quiet
/// still does.
@MainActor
@Suite struct QuietTurnNoticeTests {
    @Test func aQuietTurnNotifiesNobody() {
        let server = ServerModel(config: ServerConfig(name: "s", endpoint: .defaultLocal))
        let finished = Event(
            seq: 2, agentId: "a", ts: 2, body: .turnCompleted(turnId: "t", status: .ok, usage: nil, costUsd: nil))
        #expect(AppModel.notice(for: finished, in: server) != nil)
        #expect(AppModel.soundEvent(for: finished.body) == .done)

        server.apply(Event(seq: 1, agentId: "a", ts: 1, body: .turnQuiet(turnId: "t", reason: nil)))
        #expect(AppModel.notice(for: finished, in: server) == nil)
        #expect(AppModel.soundEvent(for: finished.body, quiet: true) == nil)
        // A quiet turn that fails is still an error the person should see.
        let failed = Event(seq: 3, agentId: "a", ts: 3, body: .error(message: "boom"))
        #expect(AppModel.notice(for: failed, in: server) != nil)
    }
}
