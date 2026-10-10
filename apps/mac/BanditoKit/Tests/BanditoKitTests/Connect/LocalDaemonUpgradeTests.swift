import Foundation
import Testing

@testable import BanditoKit

@Suite struct LocalDaemonUpgradeTests {
    private func decide(
        server: String?, bundled: String?, local: Bool = true, qa: Bool = false
    ) -> Bool {
        LocalDaemonUpgrade.decide(serverVersion: server, bundledVersion: bundled, isLocalServer: local, isQA: qa)
    }

    @Test func aNewerBundledDaemonIsInstalled() {
        #expect(decide(server: "0.1.1", bundled: "0.1.2"))
        #expect(decide(server: "0.1.2", bundled: "0.2.0"))
        #expect(decide(server: "0.9.9", bundled: "1.0.0"))
    }

    @Test func aReleaseReplacesItsPreRelease() {
        #expect(decide(server: "0.1.2-beta.1", bundled: "0.1.2"))
        #expect(!decide(server: "0.1.2", bundled: "0.1.2-beta.1"))
    }

    @Test func anEqualVersionIsLeftAlone() {
        #expect(!decide(server: "0.1.2", bundled: "0.1.2"))
    }

    @Test func anOlderBundledDaemonIsNeverInstalled() {
        #expect(!decide(server: "0.1.2", bundled: "0.1.1"))
        #expect(!decide(server: "1.0.0", bundled: "0.9.0"))
    }

    @Test func aServerThatIsNotThisMacIsLeftAlone() {
        #expect(!decide(server: "0.1.1", bundled: "0.1.2", local: false))
    }

    @Test func aQACopyNeverUpgrades() {
        #expect(!decide(server: "0.1.1", bundled: "0.1.2", qa: true))
    }

    @Test func aMissingVersionMeansNoUpgrade() {
        #expect(!decide(server: nil, bundled: "0.1.2"))
        #expect(!decide(server: "0.1.1", bundled: nil))
        #expect(!decide(server: nil, bundled: nil))
    }

    @Test func aVersionThatDoesNotParseMeansNoUpgrade() {
        #expect(!decide(server: "junk", bundled: "0.1.2"))
        #expect(!decide(server: "0.1.1", bundled: "0.1"))
        #expect(!decide(server: "0.1.1", bundled: ""))
        #expect(!decide(server: "0.1.1", bundled: "bandito 0.1.2"))
    }

    @Test func theVersionIsReadFromTheAnswerOfVersion() {
        #expect(LocalDaemonUpgrade.parseVersion("bandito 0.1.2\n") == "0.1.2")
        #expect(LocalDaemonUpgrade.parseVersion("bandito 0.1.2-beta.1") == "0.1.2-beta.1")
        #expect(LocalDaemonUpgrade.parseVersion("  bandito   0.2.0 ") == "0.2.0")
    }

    @Test func anyOtherAnswerHasNoVersion() {
        #expect(LocalDaemonUpgrade.parseVersion("") == nil)
        #expect(LocalDaemonUpgrade.parseVersion("0.1.2") == nil)
        #expect(LocalDaemonUpgrade.parseVersion("bandito") == nil)
        #expect(LocalDaemonUpgrade.parseVersion("other 0.1.2") == nil)
        #expect(LocalDaemonUpgrade.parseVersion("bandito 0.1") == nil)
        #expect(LocalDaemonUpgrade.parseVersion("bandito x.y.z") == nil)
        #expect(LocalDaemonUpgrade.parseVersion("bandito 0.1.2 extra") == nil)
    }

    @Test func theSocketAndAFlaggedServerAreThisMac() throws {
        #expect(LocalDaemonUpgrade.isThisMac(ServerConfig(name: "Mac", endpoint: .local(socketPath: "/h/.bandito/bandito.sock"))))
        let flagged = ServerConfig(
            name: "Mac", endpoint: .webSocket(url: try #require(URL(string: "ws://127.0.0.1:17779/v1/rpc"))), isThisMac: true)
        #expect(LocalDaemonUpgrade.isThisMac(flagged))
    }

    /// A loopback address is not proof: without the flag, a server on 127.0.0.1 is not this Mac's daemon, until
    /// `confirmsThisMac` has checked it (see ThisMacTests).
    @Test func aLoopbackServerWithoutTheFlagIsNotThisMac() throws {
        let loopback = ServerConfig(
            name: "Mac", endpoint: .webSocket(url: try #require(URL(string: "ws://127.0.0.1:17779/v1/rpc"))))
        #expect(!LocalDaemonUpgrade.isThisMac(loopback))
        #expect(!LocalDaemonUpgrade.isThisMac(ServerConfig(name: "Mac", endpoint: .ssh(target: "localhost", remotePort: 7878))))
    }

    @Test func aRemoteServerIsNotThisMacEvenOnItsOwnFlag() throws {
        let remote = ServerConfig(
            name: "Remote", endpoint: .webSocket(url: try #require(URL(string: "wss://mac.example.ts.net/v1/rpc"))))
        #expect(!LocalDaemonUpgrade.isThisMac(remote))
        #expect(!LocalDaemonUpgrade.isThisMac(ServerConfig(
            name: "LAN", endpoint: .webSocket(url: try #require(URL(string: "ws://192.168.1.20:7878/v1/rpc"))))))
    }
}
