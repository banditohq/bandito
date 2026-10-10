import Testing

@testable import BanditoKit

@Suite struct InstallErrorTextTests {
    @Test func aReleaseNotPublishedNamesTheVersionTheAppNeeds() {
        let error = InstallError.releaseStillPublishing("0.2.0")
        #expect(error.errorDescription == "Bandito 0.2.0 for servers is not released yet. Update the app or try again later.")
    }
}
