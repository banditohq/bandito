import Foundation
import Testing

@testable import BanditoKit

/// `Include` in `~/.ssh/config`: relative paths, glob patterns, cycles and depth. Each test writes its own
/// `.ssh` directory under the temporary folder, so nothing in the real home is read.
@Suite struct SSHConfigIncludeTests {
    /// A fresh directory standing in for `~/.ssh`, with a `conf.d` folder inside. The caller removes it.
    private func makeSSHDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bandito-ssh-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "conf.d", directoryHint: .isDirectory), withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to name: String, in directory: URL) throws {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func relativeIncludeIsReadFromTheSSHDirectory() throws {
        let directory = try makeSSHDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("Host from-include\n  HostName 10.1.1.1\n", to: "extra.conf", in: directory)

        let entries = SSHConfigReader.hostEntries(
            configText: "Include extra.conf\nHost main\n  HostName 10.0.0.2\n", sshDirectory: directory)

        #expect(entries.map(\.alias) == ["from-include", "main"])
        #expect(entries[0].hostName == "10.1.1.1")
        #expect(entries[1].hostName == "10.0.0.2")
    }

    @Test func globIncludeReadsEveryMatchingFileInSortedOrder() throws {
        let directory = try makeSSHDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("Host beta\n", to: "conf.d/b.conf", in: directory)
        try write("Host alpha\n", to: "conf.d/a.conf", in: directory)
        try write("Host ignored\n", to: "conf.d/readme.txt", in: directory)

        let entries = SSHConfigReader.hostEntries(configText: "Include conf.d/*.conf\n", sshDirectory: directory)

        #expect(entries.map(\.alias) == ["alpha", "beta"])
    }

    @Test func missingIncludeIsIgnored() throws {
        let directory = try makeSSHDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let entries = SSHConfigReader.hostEntries(
            configText: "Include nothing-here.conf\nHost only\n", sshDirectory: directory)

        #expect(entries.map(\.alias) == ["only"])
    }

    @Test func includeCycleDoesNotLoop() throws {
        let directory = try makeSSHDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("Host alpha\nInclude b.conf\n", to: "a.conf", in: directory)
        try write("Host beta\nInclude a.conf\n", to: "b.conf", in: directory)

        let entries = SSHConfigReader.hostEntries(configText: "Include a.conf\n", sshDirectory: directory)

        #expect(entries.map(\.alias) == ["alpha", "beta"])
    }

    @Test func includeChainStopsAtDepthEight() throws {
        let directory = try makeSSHDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // f1 ... f12, each naming one host and including the next file.
        for index in 1...12 {
            try write("Host h\(index)\nInclude f\(index + 1).conf\n", to: "f\(index).conf", in: directory)
        }

        let entries = SSHConfigReader.hostEntries(configText: "Include f1.conf\n", sshDirectory: directory)

        #expect(entries.map(\.alias) == (1...8).map { "h\($0)" })
    }

    @Test func includeInsideAHostBlockAddsSettingsToThatBlockOnly() throws {
        let directory = try makeSSHDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("HostName 10.0.0.9\n", to: "inc.conf", in: directory)

        let entries = SSHConfigReader.hostEntries(
            configText: "Host a\nInclude inc.conf\nHost b\n", sshDirectory: directory)

        #expect(entries.map(\.alias) == ["a", "b"])
        #expect(entries[0].hostName == "10.0.0.9")
        #expect(entries[1].hostName == nil)
    }

    @Test func aliasInTwoFilesIsListedOnceWithTheFirstSettings() throws {
        let directory = try makeSSHDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("Host shared\n  HostName first.example.com\n", to: "one.conf", in: directory)
        try write("Host shared\n  HostName second.example.com\n", to: "two.conf", in: directory)

        let entries = SSHConfigReader.hostEntries(
            configText: "Include one.conf two.conf\n", sshDirectory: directory)

        #expect(entries.map(\.alias) == ["shared"])
        #expect(entries.first?.hostName == "first.example.com")
    }

    @Test func multipleNamesOnOneHostLineGiveOneEntryEach() {
        let entries = SSHConfigReader.hostEntries(configText: "Host a b   c\tdd\n")
        #expect(entries.map(\.alias) == ["a", "b", "c", "dd"])
    }

    @Test func wildcardAndNegatedPatternsAreSkipped() {
        let entries = SSHConfigReader.hostEntries(configText: "Host *.corp web-? !bad good\n")
        #expect(entries.map(\.alias) == ["good"])
    }

    @Test func keywordIsCaseInsensitiveAndEqualsSignSeparates() {
        let text = "HOST=box\nhOsTnAmE=box.example.com\nPORT 2200\n"
        #expect(
            SSHConfigReader.hostEntries(configText: text)
                == [SSHHostEntry(alias: "box", hostName: "box.example.com", user: nil, port: 2200)])
    }

    @Test func quotedHostNameWithSpaceIsDroppedAndTheOthersKept() {
        let entries = SSHConfigReader.hostEntries(configText: "Host \"my box\" other\n")
        #expect(entries.map(\.alias) == ["other"])
    }

    @Test func quotedHostNameWithoutSpaceIsUnquoted() {
        let entries = SSHConfigReader.hostEntries(configText: "Host \"prod\" \"stage\"\n")
        #expect(entries.map(\.alias) == ["prod", "stage"])
    }

    @Test func quotedIncludePathWithSpaceIsReadAsOneFile() throws {
        let directory = try makeSSHDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("Host spaced\n", to: "dir with space/x.conf", in: directory)

        let entries = SSHConfigReader.hostEntries(
            configText: "Include \"dir with space/x.conf\"\n", sshDirectory: directory)

        #expect(entries.map(\.alias) == ["spaced"])
    }

    @Test func severalQuotedIncludePathsAreReadSeparately() throws {
        let directory = try makeSSHDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("Host one\n", to: "a b.conf", in: directory)
        try write("Host two\n", to: "c.conf", in: directory)

        let entries = SSHConfigReader.hostEntries(
            configText: "Include \"a b.conf\" \"c.conf\"\n", sshDirectory: directory)

        #expect(entries.map(\.alias) == ["one", "two"])
    }
}
