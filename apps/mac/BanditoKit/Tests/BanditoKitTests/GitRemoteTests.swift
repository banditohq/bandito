import Testing

@testable import BanditoKit

@Suite struct GitRemoteTests {
    @Test func folderNameIsTheLastPathComponentWithoutGit() {
        #expect(GitRemote.folderName(from: "https://github.com/a/b.git") == "b")
        #expect(GitRemote.folderName(from: "https://github.com/a/b") == "b")
        #expect(GitRemote.folderName(from: "https://github.com/a/b/") == "b")
        #expect(GitRemote.folderName(from: "  https://github.com/a/billing.git  ") == "billing")
    }

    @Test func scpStyleSshAddress() {
        #expect(GitRemote.folderName(from: "git@host:a/b") == "b")
        #expect(GitRemote.folderName(from: "git@host:a/b.git") == "b")
        #expect(GitRemote.folderName(from: "user@host:repo.git") == "repo")
    }

    @Test func emptyAddressHasNoName() {
        #expect(GitRemote.folderName(from: "") == nil)
        #expect(GitRemote.folderName(from: "https://github.com/") == nil)
    }
}
