import Foundation
import Testing

@testable import BanditoKit

/// A daemon in safe mode (docs/ARCHITECTURE.md#backups) answers only `daemon.info` and `backups.*`. The app must
/// stay connected to it, with nothing loaded, so the Backups section can show why and restore a copy.
@MainActor
@Suite struct SafeModeConnectTests {
    nonisolated private static let safeInfo = #"{"version":"0.1.6","hostname":"test","os":"macos","arch":"arm64","started_at":1,"last_seq":0,"features":["backups"],"safe_mode":true,"safe_mode_error":"the restore failed","last_restore":{"id":"op-1","name":"bandito-20270115-080000-start.db","ok":false,"error":"the restore failed","at_ms":3}}"#

    @Test func aDaemonInSafeModeConnectsWithoutAskingForAnythingElse() async {
        let fake = FakeTransport(handlers: daemonHandlers(extra: ["daemon.info": { _ in Self.safeInfo }]))
        let (model, _) = makeModel([fake])

        await model.connect()

        #expect(model.state == .connected)
        #expect(model.info?.isSafeMode == true)
        #expect(model.info?.safeModeError == "the restore failed")
        #expect(model.info?.lastRestore?.id == "op-1")
        let sent = await fake.sentTexts()
        for method in ["agents.list", "runtimes.status", "events.subscribe"] {
            #expect(JSONRPC.requests(of: method, in: sent).isEmpty, "\(method) is refused in safe mode")
        }
        await model.disconnect()
    }

    @Test func aDaemonThatIsNotInSafeModeLoadsAgentsAsBefore() async {
        let fake = FakeTransport(handlers: daemonHandlers())
        let (model, _) = makeModel([fake])

        await model.connect()

        #expect(model.state == .connected)
        #expect(model.info?.isSafeMode == false)
        #expect(!JSONRPC.requests(of: "agents.list", in: await fake.sentTexts()).isEmpty)
        await model.disconnect()
    }
}
