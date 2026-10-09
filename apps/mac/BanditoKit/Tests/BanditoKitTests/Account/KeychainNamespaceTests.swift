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

    @Test func aQACopyGetsItsOwnServiceNamesAndIsADebugBuild() {
        #expect(
            KeychainNamespace.scoped("dev.bandito.mac.server-token", bundleID: "dev.bandito.mac.debug.qa1")
                == "dev.bandito.debug.qa1.mac.server-token")
        #expect(
            KeychainNamespace.scoped("dev.bandito.device", bundleID: "dev.bandito.mac.debug.qa3")
                == "dev.bandito.debug.qa3.device")
        #expect(KeychainNamespace.isDebugBuild(bundleID: "dev.bandito.mac.debug.qa1"))
        #expect(KeychainNamespace.debugFileStore(service: "x", bundleID: "dev.bandito.mac.debug.qa1") != nil)
    }

    @Test func theReleaseAppIsNotADebugBuild() {
        #expect(!KeychainNamespace.isDebugBuild(bundleID: "dev.bandito.mac"))
        #expect(KeychainNamespace.debugFileStore(service: "x", bundleID: "dev.bandito.mac") == nil)
    }

    @Test func otherServicesAreLeftAlone() {
        #expect(KeychainNamespace.scoped("com.example.x", bundleID: "dev.bandito.mac.debug") == "com.example.x")
        #expect(KeychainNamespace.scoped("com.example.x", bundleID: "dev.bandito.mac.debug.qa1") == "com.example.x")
    }
}
