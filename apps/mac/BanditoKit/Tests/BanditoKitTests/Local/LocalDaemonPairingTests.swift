import Foundation
import Testing

@testable import BanditoKit

// This Mac's daemon, paired as an ordinary WebSocket server (Local/LocalDaemonPairing.swift). The bandito binary is
// a scripted runner; the redeem is a stub, so nothing here opens a socket.

private let binary = URL(fileURLWithPath: "/home/u/.local/bin/bandito")
private let paired: PairResult = {
    let json = #"{"token":"bdt_local","device":{"id":"d1","name":"This Mac","created_at":1,"last_seen_at":null}}"#
    return try! RPCClient.decoder.decode(PairResult.self, from: Data(json.utf8))
}()

/// The bandito commands a healthy daemon answers: `info` with its listen address, `pair` with a code.
private func healthy(listen: String = "127.0.0.1:17779") -> ScriptedRunner {
    ScriptedRunner { _, arguments in
        if arguments.contains("info") {
            return CommandResult(status: 0, stdout: #"{"listen":"\#(listen)","running":true}"#, stderr: "")
        }
        if arguments.contains("pair") {
            return CommandResult(status: 0, stdout: #"{"code":"sunset-orbit","expires_in_ms":600000}"#, stderr: "")
        }
        return CommandResult(status: 1, stdout: "", stderr: "unknown command")
    }
}

/// Redeems only the expected code at the daemon's loopback address.
private let redeemExpected: LocalDaemonPairing.Redeem = { url, code, _ in
    guard url.absoluteString == "ws://127.0.0.1:17779/v1/rpc", code == "sunset-orbit" else {
        throw RPCError(code: RPCError.disconnected, message: "unexpected \(url) \(code)")
    }
    return paired
}

@Test func thisMacBecomesAWebSocketServerWithItsTokenAndKeepsItsIdentity() async throws {
    let id = UUID()
    let runner = healthy()
    let pairing = LocalDaemonPairing(
        runner: runner, binary: binary, home: URL(fileURLWithPath: "/tmp/h"), redeem: redeemExpected)

    let config = try await pairing.serverConfig(name: "This Mac", id: id, deviceName: "This Mac")

    #expect(config.id == id)
    #expect(config.name == "This Mac")
    #expect(config.endpoint == .webSocket(url: URL(string: "ws://127.0.0.1:17779/v1/rpc")!))
    #expect(config.token == "bdt_local")
    #expect(runner.calls.map(\.executable).allSatisfy { $0 == binary.path })
    #expect(
        runner.calls.map(\.arguments) == [
            ["--home", "/tmp/h", "info", "--json"],
            ["--home", "/tmp/h", "pair", "--json"],
        ])
}

@Test func withoutAHomeTheDaemonsDefaultHomeIsUsed() async throws {
    let runner = healthy()
    let pairing = LocalDaemonPairing(runner: runner, binary: binary, redeem: redeemExpected)

    _ = try await pairing.serverConfig(name: "This Mac", deviceName: "This Mac")

    #expect(runner.calls.map(\.arguments) == [["info", "--json"], ["pair", "--json"]])
}

@Test func theListenPortComesFromInfo() async throws {
    let pairing = LocalDaemonPairing(runner: healthy(listen: "127.0.0.1:7878"), binary: binary, redeem: { url, _, _ in
        #expect(url.absoluteString == "ws://127.0.0.1:7878/v1/rpc")
        return paired
    })

    let config = try await pairing.serverConfig(name: "This Mac", deviceName: "This Mac")

    #expect(config.endpoint == .webSocket(url: URL(string: "ws://127.0.0.1:7878/v1/rpc")!))
}

@Test func aDaemonThatIsNotRunningFailsAtTheNamedStep() async throws {
    let runner = ScriptedRunner { _, _ in
        CommandResult(status: 1, stdout: "", stderr: "warning: first\ndaemon is not running")
    }
    let pairing = LocalDaemonPairing(runner: runner, binary: binary, redeem: redeemExpected)
    do {
        _ = try await pairing.serverConfig(name: "This Mac", deviceName: "This Mac")
        Issue.record("pairing succeeded without a daemon")
    } catch let error as InstallError {
        #expect(error == .step("Reading the daemon's address", detail: "daemon is not running"))
    }
}

@Test func infoWithoutAListenAddressIsABadResponse() async throws {
    let runner = ScriptedRunner { _, arguments in
        arguments.contains("info")
            ? CommandResult(status: 0, stdout: #"{"running":false}"#, stderr: "")
            : CommandResult(status: 0, stdout: #"{"code":"x"}"#, stderr: "")
    }
    let pairing = LocalDaemonPairing(runner: runner, binary: binary, redeem: redeemExpected)
    do {
        _ = try await pairing.serverConfig(name: "This Mac", deviceName: "This Mac")
        Issue.record("pairing succeeded without a listen address")
    } catch let error as InstallError {
        #expect(error == .badResponse("info"))
    }
}

@Test func aRefusedRedeemIsAPairingFailureWithTheDaemonsMessage() async throws {
    let pairing = LocalDaemonPairing(runner: healthy(), binary: binary, redeem: { _, _, _ in
        throw RPCError(code: -32000, message: "pairing code expired")
    })
    do {
        _ = try await pairing.serverConfig(name: "This Mac", deviceName: "This Mac")
        Issue.record("pairing succeeded with a refused code")
    } catch let error as InstallError {
        #expect(error == .pairingFailed("pairing code expired"))
    }
}
