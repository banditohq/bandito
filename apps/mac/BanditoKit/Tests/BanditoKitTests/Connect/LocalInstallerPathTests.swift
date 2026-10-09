import Foundation
import Testing

@testable import BanditoKit

@Suite struct LocalInstallerPathTests {
    @Test func bundledDaemonIsInContentsHelpers() {
        let bundle = URL(fileURLWithPath: "/Applications/Bandito.app")
        let daemon = LocalInstaller.bundledDaemonURL(bundleURL: bundle)
        #expect(daemon.path == "/Applications/Bandito.app/Contents/Helpers/bandito")
    }

    @Test func bundledDaemonIsNotInMacOSFolder() {
        // On a case-insensitive volume MacOS/bandito is the app's own executable, Bandito.
        let daemon = LocalInstaller.bundledDaemonURL(bundleURL: URL(fileURLWithPath: "/Applications/Bandito.app"))
        #expect(!daemon.path.contains("/MacOS/"))
    }
}
