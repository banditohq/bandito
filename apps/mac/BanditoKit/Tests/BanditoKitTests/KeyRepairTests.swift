import Foundation
import Testing

@testable import BanditoKit

@Suite struct KeyRepairTests {
    private let loopback = URL(string: "ws://127.0.0.1:17777/v1/rpc")!
    private let remote = URL(string: "wss://srv.example.ts.net/v1/rpc")!

    private func thisMac() -> ServerConfig {
        ServerConfig(name: "This Mac", endpoint: .webSocket(url: loopback), token: "old", isThisMac: true)
    }

    @Test func aRefusedKeyOnThisMacIsRepairedOnce() {
        #expect(KeyRepair.action(for: .keyRejected, config: thisMac(), alreadyTried: false, isQA: false) == .repairThisMac)
        // The second refusal of the same event: no loop, the person is asked.
        #expect(KeyRepair.action(for: .keyRejected, config: thisMac(), alreadyTried: true, isQA: false) == .offerReconnect)
    }

    @Test func otherFailuresAreLeftAlone() {
        for kind in [FailureKind.noAnswer, .deviceRevoked, .reason("io"), .other(technical: "x")] {
            #expect(KeyRepair.action(for: kind, config: thisMac(), alreadyTried: false, isQA: false) == .none)
        }
    }

    @Test func aLoopbackAddressAloneIsNotThisMac() {
        // Any program can listen on loopback: only the flag makes a server "this Mac".
        let unflagged = ServerConfig(name: "x", endpoint: .webSocket(url: loopback), token: "t")
        #expect(KeyRepair.action(for: .keyRejected, config: unflagged, alreadyTried: false, isQA: false) == .offerReconnect)
    }

    @Test func aRemoteServerIsNeverPairedAutomatically() {
        let config = ServerConfig(name: "srv", endpoint: .webSocket(url: remote), token: "t")
        #expect(KeyRepair.action(for: .keyRejected, config: config, alreadyTried: false, isQA: false) == .offerReconnect)
        #expect(KeyRepair.reconnectAddress(for: config) == "srv.example.ts.net")
    }

    @Test func aQACopyNeverPairsWithTheInstalledDaemon() {
        #expect(KeyRepair.action(for: .keyRejected, config: thisMac(), alreadyTried: false, isQA: true) == .offerReconnect)
    }

    @Test func anSSHServerOffersItsAddress() {
        let config = ServerConfig(name: "box", endpoint: .ssh(target: "me@box.local:2222", remotePort: 7878))
        #expect(KeyRepair.reconnectAddress(for: config) == "me@box.local")
    }
}
