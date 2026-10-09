import Foundation
import Testing

@testable import BanditoKit

@Suite struct SSHTargetTests {
    @Test func parsesAliasWithoutUserOrPort() {
        let target = SSHTarget.parse("prod-1")
        #expect(target == SSHTarget(user: nil, host: "prod-1", port: nil))
        #expect(target?.description == "prod-1")
    }

    @Test func parsesUserHostAndPort() {
        let target = SSHTarget.parse("deploy@example.com:2222")
        #expect(target == SSHTarget(user: "deploy", host: "example.com", port: 2222))
        #expect(target?.description == "deploy@example.com:2222")
    }

    @Test func parsesHostWithoutUser() {
        #expect(SSHTarget.parse("  10.0.0.5  ") == SSHTarget(user: nil, host: "10.0.0.5", port: nil))
    }

    @Test func rejectsInputSSHCouldReadAsOptionsOrGarbage() {
        // A leading dash would be read as an ssh option, e.g. -oProxyCommand=…
        #expect(SSHTarget.parse("-oProxyCommand=curl evil") == nil)
        #expect(SSHTarget.parse("deploy@-oProxyCommand") == nil)
        #expect(SSHTarget.parse("") == nil)
        #expect(SSHTarget.parse("   ") == nil)
        #expect(SSHTarget.parse("two words") == nil)
        #expect(SSHTarget.parse("a@b@c") == nil)
        #expect(SSHTarget.parse("@host") == nil)
        #expect(SSHTarget.parse("host:") == nil)
        #expect(SSHTarget.parse("host:0") == nil)
        #expect(SSHTarget.parse("host:70000") == nil)
        #expect(SSHTarget.parse("host:abc") == nil)
        #expect(SSHTarget.parse("[::1]:22") == nil)
        #expect(SSHTarget.parse("host;rm -rf") == nil)
    }

    @Test func sshArgumentsCarryThePortAsOption() {
        #expect(SSHTarget.parse("deploy@example.com:2222")?.sshArguments == ["-p", "2222", "deploy@example.com"])
        #expect(SSHTarget.parse("prod-1")?.sshArguments == ["prod-1"])
    }

    @Test func scpArgumentsUseCapitalPAndRemotePath() {
        let target = SSHTarget.parse("deploy@example.com:2222")
        #expect(
            target?.scpArguments(local: "/tmp/bandito", remotePath: ".local/bin/bandito")
                == ["-P", "2222", "/tmp/bandito", "deploy@example.com:.local/bin/bandito"])
        #expect(
            SSHTarget.parse("prod-1")?.scpArguments(local: "/tmp/bandito", remotePath: ".local/bin/bandito")
                == ["/tmp/bandito", "prod-1:.local/bin/bandito"])
    }
}

@Suite struct SSHConfigReaderTests {
    private let config = """
        # personal hosts
        Host *
          ServerAliveInterval 60

        Host prod web-1 !staging
          HostName 10.0.0.5
          User deploy
          Port 2222

        Host dev
          hostname dev.example.com

        Match host corp
          User nobody
          Port 9999

        Host edge
          HostName "edge.example.com"
          Include ~/.ssh/extra
        """

    @Test func listsConcreteAliasesWithTheirSettings() {
        let entries = SSHConfigReader.hostEntries(configText: config)

        #expect(entries.map(\.alias) == ["prod", "web-1", "dev", "edge"])
        #expect(entries[0] == SSHHostEntry(alias: "prod", hostName: "10.0.0.5", user: "deploy", port: 2222))
        #expect(entries[1] == SSHHostEntry(alias: "web-1", hostName: "10.0.0.5", user: "deploy", port: 2222))
        #expect(entries[2] == SSHHostEntry(alias: "dev", hostName: "dev.example.com", user: nil, port: nil))
    }

    @Test func matchBlockEndsTheHostBlockSoItsOptionsDoNotLeak() {
        let entries = SSHConfigReader.hostEntries(configText: config)
        // `Port 9999` sits under `Match`, so it must not attach to `dev`.
        #expect(entries.first { $0.alias == "dev" }?.port == nil)
    }

    @Test func quotedValuesAreUnquoted() {
        let entries = SSHConfigReader.hostEntries(configText: config)
        #expect(entries.last?.hostName == "edge.example.com")
    }

    @Test func keyEqualsValueSyntaxIsRead() {
        let text = "Host box\n  HostName=box.example.com\n  Port=2200\n"
        #expect(
            SSHConfigReader.hostEntries(configText: text)
                == [SSHHostEntry(alias: "box", hostName: "box.example.com", user: nil, port: 2200)])
    }

    @Test func knownHostsKeepPlainNamesAndSkipHashedAndMarkedLines() {
        let text = """
            # comment
            github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMq
            [example.com]:2222 ssh-rsa AAAAB3NzaC1yc2E
            |1|c2FsdA==|aGFzaA== ssh-ed25519 AAAAC3NzaC1lZDI1NTE5
            @cert-authority *.corp ssh-rsa AAAAB3NzaC1yc2E
            @revoked old.example.com ssh-rsa AAAAB3NzaC1yc2E
            10.0.0.5,10.0.0.6 ecdsa-sha2-nistp256 AAAAE2VjZHNh
            *.internal ssh-ed25519 AAAAC3NzaC1lZDI1NTE5
            github.com ssh-rsa AAAAB3NzaC1yc2E
            """

        #expect(
            SSHConfigReader.knownHosts(text)
                == ["github.com", "example.com:2222", "10.0.0.5", "10.0.0.6"])
    }

    @Test func suggestionsListAliasesFirstWithoutDuplicates() {
        let known = "github.com ssh-ed25519 AAAA\nprod ssh-ed25519 AAAA\n"

        #expect(
            SSHConfigReader.suggestions(config: config, knownHosts: known)
                == ["prod", "web-1", "dev", "edge", "github.com"])
    }
}
