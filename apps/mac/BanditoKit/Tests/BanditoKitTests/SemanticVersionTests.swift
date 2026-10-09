import Testing

@testable import BanditoKit

@Suite struct SemanticVersionTests {
    @Test func parsesPlainAndPrefixedVersions() throws {
        let plain = try #require(SemanticVersion("0.5.1"))
        let prefixed = try #require(SemanticVersion("v0.5.1"))
        #expect(plain == prefixed)
        #expect(plain.major == 0 && plain.minor == 5 && plain.patch == 1)
    }

    @Test func rejectsGarbage() {
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("1.2") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
    }

    @Test func comparesNumericallyNotAsText() throws {
        let v9 = try #require(SemanticVersion("0.9.0"))
        let v10 = try #require(SemanticVersion("0.10.0"))
        #expect(v9 < v10)
        #expect(try #require(SemanticVersion("0.5.1")) < #require(SemanticVersion("0.5.2")))
        #expect(try #require(SemanticVersion("1.0.0")) > #require(SemanticVersion("0.99.99")))
    }

    @Test func prereleaseIsBeforeTheReleaseAndBuildMetadataIsIgnored() throws {
        let beta = try #require(SemanticVersion("0.6.0-beta.1"))
        let release = try #require(SemanticVersion("0.6.0"))
        #expect(beta < release)
        #expect(try #require(SemanticVersion("0.6.0+build.7")) == release)
    }
}
