import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoUI

/// Pure logic behind the Files mode: ordering, file types, names, paths, relative time.
@Suite struct FilesLogicTests {
    static func entry(_ name: String, dir: Bool = false, size: Int64 = 0, modifiedMs: Int64 = 0) -> FsEntry {
        let ext = name.contains(".") && !dir ? name.split(separator: ".").last.map { String($0).lowercased() } : nil
        return FsEntry(
            name: name, path: "/w/\(name)", kind: dir ? .dir : .file, size: size, modifiedMs: modifiedMs,
            hidden: name.hasPrefix("."), readonly: false, symlinkTarget: nil, ext: ext)
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Sorting

    @Test func foldersComeFirstThenNaturalNameOrder() {
        let sorted = FileSorting.sorted([
            Self.entry("file10.txt"), Self.entry("webhook.rs"), Self.entry("src", dir: true),
            Self.entry("file2.txt"), Self.entry("Cargo.toml"), Self.entry("tests", dir: true),
        ])
        #expect(sorted.map(\.name) == ["src", "tests", "Cargo.toml", "file2.txt", "file10.txt", "webhook.rs"])
    }

    // MARK: File types

    @Test func categoryFromExtension() {
        #expect(FileTypes.category(name: "README.md", ext: "md", kind: .file) == .markdown)
        #expect(FileTypes.category(name: "webhook.rs", ext: "rs", kind: .file) == .code)
        #expect(FileTypes.category(name: "Cargo.toml", ext: "toml", kind: .file) == .config)
        #expect(FileTypes.category(name: "notes.txt", ext: "txt", kind: .file) == .text)
        #expect(FileTypes.category(name: "flow.PNG", ext: "png", kind: .file) == .image)
        #expect(FileTypes.category(name: "invoice.pdf", ext: "pdf", kind: .file) == .pdf)
        #expect(FileTypes.category(name: "demo.mp4", ext: "mp4", kind: .file) == .video)
        #expect(FileTypes.category(name: "voice.m4a", ext: "m4a", kind: .file) == .audio)
        #expect(FileTypes.category(name: "app.zip", ext: "zip", kind: .file) == .binary)
        #expect(FileTypes.category(name: "src", ext: nil, kind: .dir) == .folder)
        #expect(FileTypes.category(name: "link", ext: nil, kind: .symlink) == .other)
    }

    @Test func viewerKindFromCategory() {
        #expect(FileTypes.viewer(for: .markdown) == .markdown)
        #expect(FileTypes.viewer(for: .code) == .text)
        #expect(FileTypes.viewer(for: .config) == .text)
        #expect(FileTypes.viewer(for: .image) == .image)
        #expect(FileTypes.viewer(for: .pdf) == .pdf)
        #expect(FileTypes.viewer(for: .video) == .media)
        #expect(FileTypes.viewer(for: .audio) == .media)
        #expect(FileTypes.viewer(for: .binary) == .binary)
        #expect(FileTypes.viewer(for: .folder) == nil)
    }

    // MARK: Names

    @Test func splitsExtensionFromStem() {
        #expect(FileNaming.split("webhook.rs") == ("webhook", "rs"))
        #expect(FileNaming.split("archive.tar.gz") == ("archive.tar", "gz"))
        #expect(FileNaming.split(".env") == (".env", nil))
        #expect(FileNaming.split("Makefile") == ("Makefile", nil))
    }

    @Test func nextFreeNameKeepsExtension() {
        #expect(FileNaming.nextFreeName(for: "file.txt", existing: []) == "file.txt")
        #expect(FileNaming.nextFreeName(for: "file.txt", existing: ["file.txt"]) == "file 2.txt")
        #expect(FileNaming.nextFreeName(for: "file.txt", existing: ["file.txt", "file 2.txt"]) == "file 3.txt")
        #expect(FileNaming.nextFreeName(for: "notes", existing: ["notes"]) == "notes 2")
    }

    @Test func copyNameUsesKopiyaSuffix() {
        #expect(FileNaming.copyName(for: "webhook.rs", isFolder: false, existing: []) == "webhook копия.rs")
        #expect(
            FileNaming.copyName(for: "webhook.rs", isFolder: false, existing: ["webhook копия.rs"])
                == "webhook копия 2.rs")
        #expect(FileNaming.copyName(for: "tests", isFolder: true, existing: []) == "tests копия")
    }

    // MARK: Paths

    @Test func breadcrumbsFromHomeUseTilde() {
        let crumbs = FilePath.crumbs(for: "/home/me/projects/billing", home: "/home/me")
        #expect(crumbs.map(\.title) == ["~", "projects", "billing"])
        #expect(crumbs.map(\.path) == ["/home/me", "/home/me/projects", "/home/me/projects/billing"])
    }

    @Test func breadcrumbsOfHomeItself() {
        let crumbs = FilePath.crumbs(for: "/home/me", home: "/home/me")
        #expect(crumbs == [PathCrumb(title: "~", path: "/home/me")])
    }

    @Test func breadcrumbsOfAbsolutePathStartAtRoot() {
        let crumbs = FilePath.crumbs(for: "/srv/api", home: "/home/me")
        #expect(crumbs.map(\.title) == ["/", "srv", "api"])
        #expect(crumbs.map(\.path) == ["/", "/srv", "/srv/api"])
        #expect(FilePath.crumbs(for: "/srv/api", home: nil).first?.title == "/")
    }

    @Test func parentOfPath() {
        #expect(FilePath.parent(of: "/srv/api") == "/srv")
        #expect(FilePath.parent(of: "/srv") == "/")
        #expect(FilePath.parent(of: "/") == nil)
    }

    // MARK: Relative time

    @Test func relativeTimeBuckets() {
        let calendar = Self.utc
        let now = Date(timeIntervalSince1970: 1_791_530_000)  // 2026-10-07 … any fixed instant
        func ms(_ seconds: TimeInterval) -> Int64 { Int64((now.timeIntervalSince1970 - seconds) * 1000) }

        #expect(RelativeTime.bucket(ms: ms(20), now: now, calendar: calendar) == .justNow)
        #expect(RelativeTime.bucket(ms: ms(5 * 60), now: now, calendar: calendar) == .minutes(5))
        #expect(RelativeTime.bucket(ms: ms(3 * 3600), now: now, calendar: calendar) == .today)
        #expect(RelativeTime.bucket(ms: ms(26 * 3600), now: now, calendar: calendar) == .yesterday)
        #expect(RelativeTime.bucket(ms: ms(9 * 86400), now: now, calendar: calendar) == .earlier)
    }

    @Test func modifiedInTheFutureIsJustNow() {
        let now = Date(timeIntervalSince1970: 1_791_530_000)
        let future = Int64((now.timeIntervalSince1970 + 300) * 1000)
        #expect(RelativeTime.bucket(ms: future, now: now, calendar: Self.utc) == .justNow)
    }
}
