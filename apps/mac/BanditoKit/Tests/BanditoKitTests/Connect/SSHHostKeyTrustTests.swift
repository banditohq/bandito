import Foundation
import Testing

@testable import BanditoKit

/// Scripted runner for ssh -G, ssh-keyscan (answers per key type) and ssh-keygen (fingerprint of the stdin key).
actor FakeKeyRunner: CommandRunner {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
    }
    private(set) var calls: [Call] = []
    private var scans: [[String: String]]
    private let config: String
    private let lookup: String

    /// `scans`: one dictionary per keyscan round, from key type to the scan output (missing type = no key).
    /// `lookup`: what `ssh-keygen -F` finds in known_hosts (empty = no entry).
    init(config: String, scans: [[String: String]], lookup: String = "") {
        self.config = config
        self.scans = scans
        self.lookup = lookup
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments))
        if executable == SSHInstaller.sshExecutable {
            return CommandResult(status: 0, stdout: config, stderr: "")
        }
        if executable == SSHHostKeyTrust.keygenPath, arguments.first == "-F" {
            return CommandResult(status: lookup.isEmpty ? 1 : 0, stdout: lookup, stderr: "")
        }
        if executable == SSHHostKeyTrust.keygenPath {
            let text = String(decoding: stdin ?? Data(), as: UTF8.self)
            let parts = text.split(separator: " ")
            let key = parts.count >= 3 ? String(parts[2].prefix(40)) : "none"
            return CommandResult(status: 0, stdout: "256 SHA256:\(key) host (ED25519)\n", stderr: "")
        }
        // keyscan: answer for the requested type of the current round.
        let type = arguments.firstIndex(of: "-t").map { arguments[$0 + 1] } ?? ""
        let round = scans.isEmpty ? [:] : scans.removeFirst()
        if let output = round[type] {
            return CommandResult(status: 0, stdout: output, stderr: "")
        }
        return CommandResult(status: 1, stdout: "", stderr: "")
    }
}

@Suite struct SSHHostKeyTrustTests {
    static let ed25519 = "server.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterial\n"
    static let ed25519Other = "server.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnotherKeyEntirely\n"
    static let ecdsa = "server.example ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBExample\n"
    static let plainConfig = """
        hostname 203.0.113.7
        port 2222
        proxyjump none
        proxycommand none
        """

    private func target(_ text: String) throws -> SSHTarget {
        try #require(SSHTarget.parse(text))
    }

    private func tempKnownHosts() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "kh-\(UUID().uuidString)")
    }

    @Test func configIsReadWithoutConnectingAndArgumentsAreAnArray() throws {
        let arguments = SSHHostKeyTrust.configArguments(for: try target("deploy@server.example:2222"))
        #expect(arguments == ["-G", "-p", "2222", "deploy@server.example"])
    }

    @Test func injectionAttemptsDoNotBecomeArguments() {
        #expect(SSHTarget.parse("server.example;rm -rf ~") == nil)
        #expect(SSHTarget.parse("-oProxyCommand=evil") == nil)
        #expect(SSHTarget.parse("server.example $(id)") == nil)
    }

    @Test func theRealHostAndPortComeFromTheConfigNotTheAlias() throws {
        let endpoint = SSHHostKeyTrust.endpoint(fromConfig: Self.plainConfig, target: try target("prod"))
        #expect(endpoint.host == "203.0.113.7")
        #expect(endpoint.port == 2222)
        #expect(endpoint.hostKeyAlias == nil)
        #expect(endpoint.viaProxy == false)
        #expect(endpoint.knownHostsField == "[203.0.113.7]:2222")
    }

    @Test func aHostKeyAliasNamesTheKnownHostsEntry() throws {
        let config = "hostname 203.0.113.7\nport 22\nhostkeyalias prod-key\nproxyjump none\n"
        let endpoint = SSHHostKeyTrust.endpoint(fromConfig: config, target: try target("prod"))
        #expect(endpoint.knownHostsField == "prod-key")
    }

    @Test func aJumpHostOrCommandMeansNoTrustHere() throws {
        let jump = SSHHostKeyTrust.endpoint(
            fromConfig: "hostname 10.0.0.5\nport 22\nproxyjump bastion\n", target: try target("inner"))
        #expect(jump.viaProxy)
        let command = SSHHostKeyTrust.endpoint(
            fromConfig: "hostname 10.0.0.5\nport 22\nproxycommand nc %h %p\n", target: try target("inner"))
        #expect(command.viaProxy)
    }

    @Test func keyscanAsksForOneTypeAtATime() {
        #expect(SSHHostKeyTrust.keyscanArguments(host: "203.0.113.7", port: 22, keyType: "ed25519")
            == ["-T", "5", "-t", "ed25519", "-p", "22", "203.0.113.7"])
    }

    @Test func previewTriesEd25519FirstThenEcdsaThenRsa() async throws {
        let runner = FakeKeyRunner(config: Self.plainConfig, scans: [
            ["ed25519": ""],
            ["ecdsa": Self.ecdsa],
        ])
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: tempKnownHosts())
        let preview = try await trust.preview(try target("server.example"))
        #expect(preview.keyType == "ecdsa")
        #expect(preview.fingerprint.hasPrefix("SHA256:"))
        let scans = await runner.calls.filter { $0.executable == SSHHostKeyTrust.keyscanPath }
        let types = scans.map { call in call.arguments.firstIndex(of: "-t").map { call.arguments[$0 + 1] } }
        #expect(types == ["ed25519", "ecdsa"])
    }

    @Test func previewWritesNothing() async throws {
        let runner = FakeKeyRunner(config: Self.plainConfig, scans: [["ed25519": Self.ed25519]])
        let file = tempKnownHosts()
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: file)
        _ = try await trust.preview(try target("server.example"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aServerWithNoKeyIsReported() async throws {
        let runner = FakeKeyRunner(config: Self.plainConfig, scans: [[:]])
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: tempKnownHosts())
        await #expect(throws: SSHHostKeyError.noKey) {
            _ = try await trust.preview(try target("server.example"))
        }
    }

    @Test func aJumpHostIsNotScannedAtAll() async throws {
        let runner = FakeKeyRunner(
            config: "hostname 10.0.0.5\nport 22\nproxyjump bastion\n", scans: [["ed25519": Self.ed25519]])
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: tempKnownHosts())
        await #expect(throws: SSHHostKeyError.viaProxy) {
            _ = try await trust.preview(try target("inner"))
        }
        let scans = await runner.calls.filter { $0.executable == SSHHostKeyTrust.keyscanPath }
        #expect(scans.isEmpty)
    }

    @Test func trustWritesExactlyTheReviewedLines() async throws {
        let runner = FakeKeyRunner(config: Self.plainConfig, scans: [["ed25519": Self.ed25519], ["ed25519": Self.ed25519]])
        let file = tempKnownHosts()
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: file)
        let host = try target("server.example")
        let preview = try await trust.preview(host)
        try await trust.trust(preview, for: host)
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written == "[203.0.113.7]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterial\n")
    }

    @Test func aDifferentKeyOnTheSecondScanWritesNothing() async throws {
        let runner = FakeKeyRunner(config: Self.plainConfig, scans: [
            ["ed25519": Self.ed25519],
            ["ed25519": Self.ed25519Other],
        ])
        let file = tempKnownHosts()
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: file)
        let host = try target("server.example")
        let preview = try await trust.preview(host)
        await #expect(throws: SSHHostKeyError.changedBetweenChecks) {
            try await trust.trust(preview, for: host)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func commentLinesDoNotCountAsAChange() async throws {
        let withComment = "# server.example:22 SSH-2.0-OpenSSH\n" + Self.ed25519
        let runner = FakeKeyRunner(config: Self.plainConfig, scans: [["ed25519": Self.ed25519], ["ed25519": withComment]])
        let file = tempKnownHosts()
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: file)
        let host = try target("server.example")
        let preview = try await trust.preview(host)
        try await trust.trust(preview, for: host)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func theAliasIsWrittenAsTheKnownHostsName() async throws {
        let config = "hostname 203.0.113.7\nport 22\nhostkeyalias prod-key\nproxyjump none\n"
        let runner = FakeKeyRunner(config: config, scans: [["ed25519": Self.ed25519], ["ed25519": Self.ed25519]])
        let file = tempKnownHosts()
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: file)
        let host = try target("prod")
        let preview = try await trust.preview(host)
        try await trust.trust(preview, for: host)
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.hasPrefix("prod-key ssh-ed25519 "))
    }

    @Test func trustWritesToTheFileSshConfigurationNames() async throws {
        let custom = tempKnownHosts()
        let config = "hostname 203.0.113.7\nport 2222\nproxyjump none\nuserknownhostsfile \(custom.path) /other\n"
        let runner = FakeKeyRunner(config: config, scans: [["ed25519": Self.ed25519], ["ed25519": Self.ed25519]])
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: tempKnownHosts())
        let host = try target("server.example")
        let preview = try await trust.preview(host)
        try await trust.trust(preview, for: host)
        #expect(FileManager.default.fileExists(atPath: custom.path))
        #expect(try String(contentsOf: custom, encoding: .utf8).hasPrefix("[203.0.113.7]:2222 ssh-ed25519 "))
    }

    @Test func aTildeInTheConfiguredFileIsExpanded() throws {
        let endpoint = SSHHostKeyTrust.endpoint(
            fromConfig: "hostname a.example\nport 22\nuserknownhostsfile ~/.ssh/custom_hosts ~/.ssh/other\n",
            target: try target("a"))
        #expect(endpoint.knownHostsPath == NSHomeDirectory() + "/.ssh/custom_hosts")
    }

    @Test func aKnownHostWithAnotherKeyOfTheSameTypeIsNotOverwritten() async throws {
        let oldLine = "[203.0.113.7]:2222 ssh-ed25519 AAAAOLDKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n"
        let runner = FakeKeyRunner(config: Self.plainConfig, scans: [["ed25519": Self.ed25519]], lookup: oldLine)
        let file = tempKnownHosts()
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: file)
        await #expect(throws: SSHHostKeyError.keyChangedSincePreviousVisit(host: "[203.0.113.7]:2222")) {
            _ = try await trust.preview(try target("server.example"))
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aKeyAppearingAfterThePreviewIsNotWritten() async throws {
        let oldLine = "[203.0.113.7]:2222 ssh-ed25519 AAAAOLDKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n"
        let runner = FakeKeyRunner(config: Self.plainConfig, scans: [["ed25519": Self.ed25519], ["ed25519": Self.ed25519]])
        let file = tempKnownHosts()
        let trust = SSHHostKeyTrust(runner: runner, knownHosts: file)
        let host = try target("server.example")
        let preview = try await trust.preview(host)
        let conflicting = FakeKeyRunner(config: Self.plainConfig, scans: [["ed25519": Self.ed25519]], lookup: oldLine)
        let later = SSHHostKeyTrust(runner: conflicting, knownHosts: file)
        await #expect(throws: SSHHostKeyError.self) {
            try await later.trust(preview, for: host)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func anEntryWithTheSameKeyIsNoConflict() {
        let previous = SSHHostKeyTrust.previousKeys(fromLookup: "# Host h found: line 1\nh ssh-ed25519 KEYA\n")
        let shown = ["h ssh-ed25519 KEYA"]
        #expect(!SSHHostKeyTrust.conflicts(previous: previous, shown: shown))
    }

    @Test func anEntryOfAnotherTypeIsNoConflict() {
        let previous = SSHHostKeyTrust.previousKeys(fromLookup: "h ssh-rsa KEYRSA\n")
        let shown = ["h ssh-ed25519 KEYED"]
        #expect(!SSHHostKeyTrust.conflicts(previous: previous, shown: shown))
    }
}


@Suite struct KnownHostsFileTests {
    private func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func existingLinesAreKept() throws {
        let file = try tempFolder().appending(path: "known_hosts")
        try "old.example ssh-ed25519 OLD\n".write(to: file, atomically: true, encoding: .utf8)
        try KnownHostsFile.append(lines: ["new.example ssh-ed25519 NEW"], to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == "old.example ssh-ed25519 OLD\nnew.example ssh-ed25519 NEW\n")
    }

    @Test func aMissingFinalNewlineIsAddedBeforeTheNewLine() throws {
        let file = try tempFolder().appending(path: "known_hosts")
        try "old.example ssh-ed25519 OLD".write(to: file, atomically: true, encoding: .utf8)
        try KnownHostsFile.append(lines: ["new.example ssh-ed25519 NEW"], to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == "old.example ssh-ed25519 OLD\nnew.example ssh-ed25519 NEW\n")
    }

    @Test func anUnreadableFileIsAnErrorAndNothingIsWritten() throws {
        let folder = try tempFolder()
        let file = folder.appending(path: "known_hosts")
        // A folder where the file should be cannot be read as data.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(throws: SSHHostKeyError.readFailed("known_hosts")) {
            try KnownHostsFile.append(lines: ["new.example ssh-ed25519 NEW"], to: file)
        }
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["known_hosts"])
    }

    @Test func aNewFileIsOwnerOnly() throws {
        let file = try tempFolder().appending(path: "known_hosts")
        try KnownHostsFile.append(lines: ["new.example ssh-ed25519 NEW"], to: file)
        #expect(try permissions(file) == 0o600)
    }

    @Test func anExistingFileKeepsItsPermissions() throws {
        let file = try tempFolder().appending(path: "known_hosts")
        try "old.example ssh-ed25519 OLD\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try KnownHostsFile.append(lines: ["new.example ssh-ed25519 NEW"], to: file)
        #expect(try permissions(file) == 0o644)
    }

    @Test func aMissingFolderIsCreatedOwnerOnly() throws {
        let folder = try tempFolder().appending(path: "ssh-new")
        let file = folder.appending(path: "known_hosts")
        try KnownHostsFile.append(lines: ["new.example ssh-ed25519 NEW"], to: file)
        #expect(try permissions(folder) == 0o700)
    }

    @Test func noTemporaryFileIsLeftBehind() throws {
        let folder = try tempFolder()
        try KnownHostsFile.append(lines: ["new.example ssh-ed25519 NEW"], to: folder.appending(path: "known_hosts"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["known_hosts"])
    }
}
