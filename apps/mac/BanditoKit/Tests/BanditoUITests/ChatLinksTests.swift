import Foundation
import Testing

@testable import BanditoUI

@Suite struct ChatLinksTests {
    /// The file links of a text, as the paths they carry.
    private func files(_ text: String) -> [String] {
        ChatLinks.find(in: text).compactMap { link in
            if case .file(let path) = link.target { return path }
            return nil
        }
    }

    /// The text each link covers, in order.
    private func covered(_ text: String) -> [String] {
        ChatLinks.find(in: text).map { String(text[$0.range]) }
    }

    @Test func absoluteAndRelativePathsWithAnExtensionAreFiles() {
        #expect(files("open /Users/me/app/Main.swift now") == ["/Users/me/app/Main.swift"])
        #expect(files("see /home/dev/notes/todo.md") == ["/home/dev/notes/todo.md"])
        #expect(files("edit Sources/BanditoUI/Team/Composer.swift") == ["Sources/BanditoUI/Team/Composer.swift"])
        #expect(files("Composer.swift") == ["Composer.swift"])
        #expect(files("~/Downloads/report.pdf") == ["~/Downloads/report.pdf"])
    }

    @Test func aTrailingLineNumberIsNotPartOfThePath() {
        #expect(files("failed at daemon/src/lib.rs:42") == ["daemon/src/lib.rs"])
        #expect(files("see Composer.swift:120:7") == ["Composer.swift"])
        #expect(covered("see Composer.swift:120") == ["Composer.swift"], "the link covers the path, not the line number")
    }

    @Test func sentencePunctuationAroundAPathIsNotPartOfIt() {
        #expect(files("Готово: README.md.") == ["README.md"])
        #expect(files("(see notes.txt)") == ["notes.txt"])
        #expect(files("файл report.pdf, и всё") == ["report.pdf"])
    }

    @Test func pathsInsideCodeSpansAreFiles() {
        #expect(files("run `cargo test` in `daemon/src/store/history.rs`") == ["daemon/src/store/history.rs"])
    }

    @Test func numbersFractionsAndDatesAreNotFiles() {
        for text in ["1/2 done", "и/или", "10.10.2026", "2026/10/10", "version 1.2.3", "pi is 3.14", "ratio 3/4.5"] {
            #expect(files(text).isEmpty, "\(text) must stay text")
        }
    }

    @Test func aBareDomainIsNotAFile() {
        #expect(files("visit example.com today").isEmpty)
        #expect(files("mail a@b.com").isEmpty)
    }

    @Test func aWebAddressIsALinkAndNotAFileInside() {
        let text = "docs at https://example.com/guide/index.html."
        let links = ChatLinks.find(in: text)
        #expect(links.count == 1)
        #expect(links.first?.target == .url("https://example.com/guide/index.html"))
        #expect(files(text).isEmpty)
    }

    @Test func aSchemeWithoutAddressIsText() {
        #expect(ChatLinks.find(in: "https://").isEmpty)
    }

    @Test func linksComeInOrderWithoutOverlap() {
        let text = "a.swift https://x.dev/b.md c/d.json"
        let links = ChatLinks.find(in: text)
        #expect(links.map { String(text[$0.range]) } == ["a.swift", "https://x.dev/b.md", "c/d.json"])
        for pair in zip(links, links.dropFirst()) {
            #expect(pair.0.range.upperBound <= pair.1.range.lowerBound)
        }
    }

    /// The path links of a text (folders and other extension-less paths), as written.
    private func paths(_ text: String) -> [String] {
        ChatLinks.find(in: text).compactMap { link in
            if case .path(let path) = link.target { return path }
            return nil
        }
    }

    @Test func absoluteAndHomePathsWithoutAnExtensionAreFolderLinks() {
        #expect(paths("open /Users/me/app now") == ["/Users/me/app"])
        #expect(paths("in ~/Documents/notes") == ["~/Documents/notes"])
        #expect(paths("see /Users/me/app/") == ["/Users/me/app"], "a trailing slash is not part of the name")
        #expect(files("see /Users/me/app").isEmpty, "a folder is not a file")
    }

    @Test func aSingleNameOrARelativePathIsNotAFolderLink() {
        #expect(paths("use /help here").isEmpty)
        #expect(paths("the src/app folder").isEmpty, "relative folders are not links")
        #expect(paths("/Users/me/my.app is a bundle").isEmpty, "a dot makes it a file name")
        #expect(paths("https://example.com/a/b").isEmpty)
    }

    @Test func relativePathsJoinTheAgentFolder() {
        #expect(ChatLinks.absolutePath("Sources/a.swift", folder: "/work/app") == "/work/app/Sources/a.swift")
        #expect(ChatLinks.absolutePath("./a.txt", folder: "/work/app/") == "/work/app/a.txt")
        #expect(ChatLinks.absolutePath("/etc/hosts.txt", folder: "/work/app") == "/etc/hosts.txt")
        #expect(ChatLinks.absolutePath("~/a.pdf", folder: "/work/app") == "~/a.pdf")
        #expect(ChatLinks.absolutePath("a.txt", folder: nil) == "a.txt")
    }
}

@Suite struct BrowserRunDomainTests {
    @Test func theHostWithoutWww() {
        #expect(BrowserRunDomain.host(of: "https://www.shop.example/cart") == "shop.example")
        #expect(BrowserRunDomain.host(of: "https://docs.example.org/a?b=1") == "docs.example.org")
    }

    @Test func noHostNoTitleDomain() {
        #expect(BrowserRunDomain.host(of: "about:blank") == nil)
        #expect(BrowserRunDomain.host(of: "") == nil)
    }

    @Test func fileLinkURLRoundTrips() {
        let url = ChatLinkText.fileURL(path: "/Users/me/my file.png")
        #expect(url != nil)
        #expect(ChatLinkText.filePath(of: url!) == "/Users/me/my file.png")
        #expect(ChatLinkText.filePath(of: URL(string: "https://example.com")!) == nil)
    }
}
