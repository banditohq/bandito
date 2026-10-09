import Foundation
import Testing

@testable import BanditoKit

@Suite struct ReleaseFeedTests {
    @Test func readsTheTagOfTheLatestRelease() throws {
        let body = Data(#"{"tag_name":"v0.5.1","name":"Bandito 0.5.1","draft":false}"#.utf8)
        #expect(try ReleaseFeed.latestVersion(from: body) == SemanticVersion("0.5.1"))
    }

    @Test func unparsableTagGivesNoVersion() {
        let body = Data(#"{"tag_name":"nightly"}"#.utf8)
        #expect(throws: (any Error).self) { try ReleaseFeed.latestVersion(from: body) }
    }

    @Test func cacheIsFreshForSixHours() {
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        #expect(ReleaseFeed.isFresh(fetchedAt: fetched, now: fetched.addingTimeInterval(6 * 3600 - 1)))
        #expect(!ReleaseFeed.isFresh(fetchedAt: fetched, now: fetched.addingTimeInterval(6 * 3600)))
    }

    @Test func updateIsOfferedOnlyWhenTheReleaseIsNewer() throws {
        let latest = try #require(SemanticVersion("0.5.1"))
        #expect(ReleaseFeed.isUpdateAvailable(current: "0.5.0", latest: latest))
        #expect(!ReleaseFeed.isUpdateAvailable(current: "0.5.1", latest: latest))
        #expect(!ReleaseFeed.isUpdateAvailable(current: "0.6.0-dev", latest: latest))
        #expect(!ReleaseFeed.isUpdateAvailable(current: "dev", latest: latest))
    }
}
