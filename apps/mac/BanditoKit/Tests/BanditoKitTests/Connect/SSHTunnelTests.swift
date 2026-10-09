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

    @Test func aPortTakenBySomeoneElseLeadsToAFreshPortThenPortHijacked() async throws {
        let ssh = try writeListeningSSH()
        let foreignOwner: Int32 = 1
        let ports = PortLog()
        let tunnel = try SSHTunnel(
            target: "prod-1", remotePort: 7878, sshPath: ssh.path,
            listeners: { port in
                ports.record(port)
                return [foreignOwner]
            })

        do {
            try await tunnel.start()
            Issue.record("expected portHijacked")
        } catch let error as SSHTunnelError {
            #expect(error == .portHijacked)
        }

        #expect(await tunnel.state == .failed(.portHijacked))
        let attempted = ports.ports
        #expect(attempted.count == SSHTunnel.maxPortAttempts)
        #expect(Set(attempted).count == SSHTunnel.maxPortAttempts)
        #expect(await tunnel.localPort == attempted.last)
    }

    @Test func aTunnelIsReadyWhenItsOwnSSHListensOnThePort() async throws {
        // Real `lsof`: the stand-in execs netcat, so the listening process is the ssh process itself.
        let ssh = try writeListeningSSH()
        let tunnel = try SSHTunnel(target: "prod-1", remotePort: 7878, sshPath: ssh.path)

        try await tunnel.start()

        #expect(await tunnel.state == .up)
        #expect(await tunnel.localURL != nil)
        await tunnel.stop()
    }

    @Test func aPortConflictInSSHsOwnWordsIsRecognised() {
        #expect(SSHTunnel.isPortConflict(stderr: "bind [127.0.0.1]:9000: Address already in use"))
        #expect(SSHTunnel.isPortConflict(stderr: "channel_setup_fwd_listener_tcpip: cannot listen to port: 9000"))
        #expect(SSHTunnel.isPortConflict(stderr: "Could not request local forwarding."))
        #expect(!SSHTunnel.isPortConflict(stderr: "Permission denied (publickey)."))
    }

    @Test func portHijackedIsPermanent() {
        #expect(SSHTunnelError.portHijacked.isPermanent)
    }
}

/// Records the ports a tunnel asked about, from any thread.
final class PortLog: @unchecked Sendable {
    // @unchecked: `recorded` is guarded by `lock`.
    private let lock = NSLock()
    private var recorded: [Int] = []

    func record(_ port: Int) {
        lock.withLock { recorded.append(port) }
    }

    var ports: [Int] {
        lock.withLock { recorded }
    }
}

/// An ssh stand-in that listens on the `-L` local port with netcat and then becomes it (`exec`), so the
/// listening process is the stand-in's own pid.
private func writeListeningSSH() throws -> URL {
    try writeFakeSSH(
        #"""
        spec=""
        while [ $# -gt 0 ]; do
            if [ "$1" = "-L" ]; then spec="$2"; fi
            shift
        done
        port=$(echo "$spec" | cut -d: -f2)
        exec /usr/bin/nc -lk 127.0.0.1 "$port"
        """#)
}
