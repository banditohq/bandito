import Testing

@testable import BanditoKit

/// One real line of ssh's stderr per class. Each case is the message ssh prints, not a paraphrase.
@Suite struct SSHFailureTests {
    @Test func unknownHostKeyIsTheTrustCase() {
        #expect(SSHFailure.classify(stderr: "Host key verification failed.\n") == .hostKeyUnknown)
    }

    @Test func changedHostKeyIsNeverOfferedTrust() {
        let stderr = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            Host key verification failed.

            """
        #expect(SSHFailure.classify(stderr: stderr) == .hostKeyChanged)
    }

    @Test func rejectedKeyIsTheAuthCase() {
        #expect(SSHFailure.classify(stderr: "deploy@203.0.113.7: Permission denied (publickey,password).\n")
            == .keyNotAccepted)
    }

    @Test func unresolvableNameIsUnknownHost() {
        #expect(SSHFailure.classify(
            stderr: "ssh: Could not resolve hostname nosuch.example: nodename nor servname provided, or not known\n")
            == .unknownHost)
    }

    @Test func refusedConnectionIsRefused() {
        #expect(SSHFailure.classify(stderr: "ssh: connect to host 203.0.113.7 port 22: Connection refused\n")
            == .refused)
    }

    @Test func silentHostIsATimeout() {
        #expect(SSHFailure.classify(stderr: "ssh: connect to host 203.0.113.7 port 22: Operation timed out\n")
            == .timedOut)
    }

    @Test func missingRouteIsNoRoute() {
        #expect(SSHFailure.classify(stderr: "ssh: connect to host 10.0.0.1 port 22: No route to host\n")
            == .noRoute)
    }

    @Test func anythingElseKeepsItsLastLine() {
        #expect(SSHFailure.classify(stderr: "kex_exchange_identification: banner\nConnection closed by remote host\n")
            == .other("Connection closed by remote host"))
    }
}
