import Foundation
import Testing

@testable import BanditoKit

@Suite struct NewChapterSupportTests {
    /// A `daemon.info` answer with only the fields the check reads, as the daemon sends them.
    func info(version: String) throws -> DaemonInfo {
        let json = #"{"version":"\#(version)","hostname":"h","os":"macos","arch":"arm64","startedAt":0,"lastSeq":0}"#
        return try RPCClient.decoder.decode(DaemonInfo.self, from: Data(json.utf8))
    }

    @Test func daemonsFromZeroOneFiveOnKnowNewChapter() throws {
        #expect(try info(version: "0.1.5").supportsNewChapter)
        #expect(try info(version: "0.1.6").supportsNewChapter)
        #expect(try info(version: "0.2.0").supportsNewChapter)
        #expect(try info(version: "1.0.0").supportsNewChapter)
    }

    @Test func olderDaemonsDoNotKnowIt() throws {
        #expect(try !info(version: "0.1.4").supportsNewChapter)
        #expect(try !info(version: "0.1.0").supportsNewChapter)
        #expect(try !info(version: "0.0.9").supportsNewChapter)
    }

    /// A release candidate of 0.1.5 is before 0.1.5 itself, so it does not get the button.
    @Test func preReleaseOfZeroOneFiveDoesNotCount() throws {
        #expect(try !info(version: "0.1.5-rc.1").supportsNewChapter)
        #expect(try !info(version: "0.1.5-beta").supportsNewChapter)
    }

    @Test func versionsCompareAsNumbers() throws {
        // "0.1.10" is newer than "0.1.5"; a text compare would say otherwise.
        #expect(try info(version: "0.1.10").supportsNewChapter)
    }

    @Test func unreadableVersionHidesTheButton() throws {
        #expect(try !info(version: "dev").supportsNewChapter)
    }
}
