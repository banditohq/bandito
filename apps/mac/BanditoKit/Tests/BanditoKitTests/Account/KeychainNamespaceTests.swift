import Testing
@testable import BanditoKit

@Suite struct KeychainNamespaceTests {
    @Test func theReleaseAppKeepsItsServiceNames() {
        #expect(KeychainNamespace.scoped("dev.bandito.account", bundleID: "dev.bandito.mac") == "dev.bandito.account")
    }

    @Test func aDebugBuildGetsItsOwnServiceNames() {
        #expect(
            KeychainNamespace.scoped("dev.bandito.account", bundleID: "dev.bandito.mac.debug")
                == "dev.bandito.debug.account")
        #expect(
            KeychainNamespace.scoped("dev.bandito.mac.server-token", bundleID: "dev.bandito.mac.debug")
                == "dev.bandito.debug.mac.server-token")
    }

    @Test func otherServicesAreLeftAlone() {
        #expect(KeychainNamespace.scoped("com.example.x", bundleID: "dev.bandito.mac.debug") == "com.example.x")
    }
}
