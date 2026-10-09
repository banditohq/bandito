import Foundation
import Testing

@testable import BanditoKit

@Suite struct SSHTunnelTests {
    @Test func argumentsForwardOneLocalPortToTheRemoteLoopbackPort() {
        let target = SSHTarget.parse("deploy@example.com:2222")!

        #expect(
            SSHTunnel.arguments(target: target, localPort: 49152, remotePort: 7878)
                == [
                    "-N",
                    "-o", "BatchMode=yes",
                    "-o", "ExitOnForwardFailure=yes",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3",
                    "-L", "127.0.0.1:49152:127.0.0.1:7878",
                    "-p", "2222", "deploy@example.com",
                ])
    }

    @Test func restartDelaysBackOffAndStopAt30Seconds() {
        #expect(SSHTunnel.delay(forRestart: 1) == .seconds(1))
        #expect(SSHTunnel.delay(forRestart: 2) == .seconds(2))
        #expect(SSHTunnel.delay(forRestart: 3) == .seconds(5))
        #expect(SSHTunnel.delay(forRestart: 4) == .seconds(10))
        #expect(SSHTunnel.delay(forRestart: 5) == .seconds(30))
        #expect(SSHTunnel.delay(forRestart: 9) == .seconds(30))
    }

    @Test func sshStderrBecomesAHumanError() {
        #expect(SSHTunnel.classify(stderr: "deploy@h: Permission denied (publickey).") == .authFailed)
        #expect(
            SSHTunnel.classify(stderr: "ssh: Could not resolve hostname nope.example: nodename nor servname provided")
                == .unknownHost)
        #expect(SSHTunnel.classify(stderr: "Host key verification failed.") == .hostKeyChanged)
        #expect(
            SSHTunnel.classify(stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@")
                == .hostKeyChanged)
        #expect(
            SSHTunnel.classify(stderr: "ssh: connect to host 10.0.0.9 port 22: Operation timed out") == .unreachable)
        #expect(
            SSHTunnel.classify(stderr: "ssh: connect to host 10.0.0.9 port 22: Connection refused") == .unreachable)
        #expect(SSHTunnel.classify(stderr: "bind [127.0.0.1]:9000: Address already in use") == nil)
        #expect(SSHTunnel.classify(stderr: "") == nil)
    }

    @Test func aTargetThatSSHCouldReadAsOptionIsRefusedAtInit() {
        #expect(throws: SSHTunnelError.invalidTarget) {
            try SSHTunnel(target: "-oProxyCommand=curl evil", remotePort: 7878)
        }
    }

    @Test func failedAuthenticationIsReportedFromStart() async throws {
        let ssh = try writeFakeSSH("echo 'deploy@example.com: Permission denied (publickey).' >&2; exit 255")
        let tunnel = try SSHTunnel(target: "deploy@example.com", remotePort: 7878, sshPath: ssh.path)

        do {
            try await tunnel.start()
            Issue.record("expected authFailed")
        } catch let error as SSHTunnelError {
            #expect(error == .authFailed)
        }
        #expect(await tunnel.state == .failed(.authFailed))
    }

    @Test func sshExitingBeforeTheForwardIsUpIsAnError() async throws {
        let ssh = try writeFakeSSH("exit 0")
        let tunnel = try SSHTunnel(target: "prod-1", remotePort: 7878, sshPath: ssh.path)

        do {
            try await tunnel.start()
            Issue.record("expected exited")
        } catch let error as SSHTunnelError {
            guard case .exited = error else {
                Issue.record("expected exited, got \(error)")
                return
            }
        }
    }

    @Test func aClosedLocalPortIsNotAccepting() async {
        #expect(await SSHTunnel.isAccepting(port: 1) == false)
    }
}
