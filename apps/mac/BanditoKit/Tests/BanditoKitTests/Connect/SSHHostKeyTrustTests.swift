import Foundation
import Testing

@testable import BanditoKit

/// Scripted runner: records every call and answers ssh-keyscan and ssh-keygen with fixed output.
actor FakeKeyRunner: CommandRunner {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var stdin: Data?
    }
    private(set) var calls: [Call] = []
    private var scans: [String]

    init(scans: [String]) {
        self.scans = scans
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, stdin: stdin))
        if executable == SSHHostKeyTrust.keyscanPath {
            return CommandResult(status: 0, stdout: scans.isEmpty ? "" : scans.removeFirst(), stderr: "")
        }
        // ssh-keygen -lf -: fingerprint of the first key in stdin.
        let text = String(decoding: stdin ?? Data(), as: UTF8.self)
        let parts = text.split(separator: " ")
        let key = parts.count >= 3 ? String(parts[2].prefix(40)) : "none"
        return CommandResult(status: 0, stdout: "256 SHA256:\(key) host (ED25519)\n", stderr: "")
    }
}

@Suite struct SSHHostKeyTrustTests {
    static let scanLine = "server.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterial\n"

    private func target(_ text: String) throws -> SSHTarget {
        try #require(SSHTarget.parse(text))
    }

    @Test func scanArgumentsAreAnArrayFromAValidatedTarget() throws {
        let arguments = SSHHostKeyTrust.keyscanArguments(for: try target("deploy@server.example:2222"))
        #expect(arguments == ["-T", "5", "-p", "2222", "server.example"])
    }

    @Test func injectionAttemptsDoNotBecomeArguments() {
        // Whatever the text, a target only exists after SSHTarget validation: nothing shell-like gets through.
        #expect(SSHTarget.parse("server.example;rm -rf ~") == nil)
        #expect(SSHTarget.parse("-oProxyCommand=evil") == nil)
        #expect(SSHTarget.parse("server.example $(id)") == nil)
    }

    @Test func fingerprintComesFromKeygenOutput() {
        #expect(SSHHostKeyTrust.fingerprint(fromKeygen: "256 SHA256:abc123XYZ host (ED25519)\n") == "SHA256:abc123XYZ")
        #expect(SSHHostKeyTrust.fingerprint(fromKeygen: "garbage") == nil)
    }

    @Test func previewScansAndFingerprintsWithoutWritingAnything() async throws {
        let runner = FakeKeyRunner(scans: [Self.scanLine])
        let file = FileManager.default.temporaryDirectory.appending(path: "kh-\(UUID().uuidString)")
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: file)
        let preview = try await trust.preview(try target("server.example"))
        #expect(preview.fingerprint.hasPrefix("SHA256:"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let calls = await runner.calls
        #expect(calls.first?.executable == SSHHostKeyTrust.keyscanPath)
        #expect(calls.first?.arguments == ["-T", "5", "server.example"])
        #expect(calls.last?.executable == SSHHostKeyTrust.keygenPath)
        #expect(calls.last?.arguments == ["-lf", "-"])
    }

    @Test func trustAppendsTheReviewedKeyOnlyAfterTheRescanMatches() async throws {
        let runner = FakeKeyRunner(scans: [Self.scanLine, Self.scanLine])
        let file = FileManager.default.temporaryDirectory.appending(path: "kh-\(UUID().uuidString)")
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: file)
        let host = try target("server.example")
        let preview = try await trust.preview(host)
        try await trust.trust(preview, for: host)
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written == Self.scanLine)
    }

    @Test func trustRefusesIfTheKeyChangedAfterReview() async throws {
        let other = "server.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnotherKeyEntirely\n"
        let runner = FakeKeyRunner(scans: [Self.scanLine, other])
        let file = FileManager.default.temporaryDirectory.appending(path: "kh-\(UUID().uuidString)")
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: file)
        let host = try target("server.example")
        let preview = try await trust.preview(host)
        await #expect(throws: SSHHostKeyError.changedSinceReview) {
            try await trust.trust(preview, for: host)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
