import Testing

@testable import BanditoUI

/// The Integrations page is listed in the Server sidebar only when the server has the feature.
@Suite struct ServerSectionVisibilityTests {
    @Test func integrationsAreHiddenWithoutTheFeature() {
        let sections = ServerSection.visible(integrations: false)
        #expect(!sections.contains(.integrations))
        #expect(sections.contains(.overview))
        #expect(sections.count == ServerSection.allCases.count - 1)
    }

    @Test func integrationsAreListedWithTheFeature() {
        #expect(ServerSection.visible(integrations: true) == ServerSection.allCases)
    }
}
