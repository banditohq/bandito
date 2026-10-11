import Foundation
import Testing

@testable import BanditoKit

/// The answer of `integrations.probe` and `integrations.test`, as the app reads it.
@Suite struct IntegrationTestWireTests {
    private func decode(_ raw: String) throws -> IntegrationTest {
        try RPCClient.decoder.decode(IntegrationTest.self, from: Data(raw.utf8))
    }

    @Test func aProbeAnswerSaysWhenTheServiceSignsInInTheBrowser() throws {
        let signsIn = try decode(#"{"ok":false,"tools":[],"oauth":true}"#)
        #expect(signsIn.oauth)
        #expect(!signsIn.ok)
        #expect(signsIn.error == nil)
    }

    @Test func anOlderDaemonsFailureHasNoSignInFlag() throws {
        let failed = try decode(#"{"ok":false,"tools":[],"error":"the server answered with HTTP 401"}"#)
        #expect(!failed.oauth)
        #expect(failed.error == "the server answered with HTTP 401")
    }
}
