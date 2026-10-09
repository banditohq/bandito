import Foundation
import Testing

@testable import BanditoKit

/// The address forms the onboarding field accepts: `user@host:port`, bare hosts, aliases, and the forms it refuses.
@Suite struct SSHTargetAddressTests {
    @Test func userHostAndPortFromTheField() {
        #expect(
            SSHTarget.parse("user@192.0.2.10:22")
                == SSHTarget(user: "user", host: "192.0.2.10", port: 22))
    }

    @Test func bareHostWithoutUserOrPort() {
        #expect(SSHTarget.parse("host") == SSHTarget(user: nil, host: "host", port: nil))
    }

    @Test func userAndHostWithoutPort() {
        #expect(SSHTarget.parse("user@host") == SSHTarget(user: "user", host: "host", port: nil))
    }

    @Test func userHostAndNonDefaultPort() {
        #expect(SSHTarget.parse("user@host:2222") == SSHTarget(user: "user", host: "host", port: 2222))
    }

    @Test func aliasFromSSHConfigKeepsItsPort() {
        let target = SSHTarget.parse("  prod-1:2200 ")
        #expect(target == SSHTarget(user: nil, host: "prod-1", port: 2200))
        #expect(target?.description == "prod-1:2200")
        #expect(target?.sshArguments == ["-p", "2200", "prod-1"])
    }

    @Test func portIsOnlyAnOptionSoScpUsesCapitalP() {
        let target = SSHTarget.parse("user@host:2222")
        #expect(target?.sshArguments == ["-p", "2222", "user@host"])
        #expect(
            target?.scpArguments(local: "/tmp/bandito", remotePath: ".local/bin/bandito")
                == ["-P", "2222", "/tmp/bandito", "user@host:.local/bin/bandito"])
    }

    @Test func noPortMeansNoPortOptionForEitherTool() {
        let target = SSHTarget.parse("user@host")
        #expect(target?.sshArguments == ["user@host"])
        #expect(target?.scpArguments(local: "/tmp/bandito", remotePath: "x") == ["/tmp/bandito", "user@host:x"])
    }

    /// IPv6 literals are not supported yet (see `SSHTarget`): the bracket forms are refused, not guessed at.
    @Test func ipv6LiteralsAreRefusedForNow() {
        #expect(SSHTarget.parse("[::1]:22") == nil)
        #expect(SSHTarget.parse("user@[fe80::1]:2200") == nil)
        #expect(SSHTarget.parse("fe80::1") == nil)
    }
}
