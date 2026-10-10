import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct FileSubtitleTests {
    @Test func folderSubtitleHasNoTrailingSeparator() {
        #expect(FileFormat.subtitle(kind: "Folder", size: "") == "Folder")
    }

    @Test func fileSubtitleJoinsKindAndSize() {
        #expect(FileFormat.subtitle(kind: "Code", size: "6.4 KB") == "Code · 6.4 KB")
    }
}

@Suite struct FileSizeCellTests {
    private func entry(_ kind: FsEntryKind) -> FsEntry {
        FsEntry(
            name: "x", path: "/x", kind: kind, size: 2_048, modifiedMs: 0, hidden: false, readonly: false,
            symlinkTarget: nil, ext: nil)
    }

    @Test func folderShowsADash() {
        #expect(FileFormat.sizeCell(of: entry(.dir)) == "—")
    }

    @Test func fileShowsItsSize() {
        #expect(FileFormat.sizeCell(of: entry(.file)) == FileFormat.size(of: entry(.file)))
        #expect(!FileFormat.sizeCell(of: entry(.file)).isEmpty)
    }

    @Test func linksAndOthersStayEmptyAsBefore() {
        #expect(FileFormat.sizeCell(of: entry(.symlink)) == "")
        #expect(FileFormat.sizeCell(of: entry(.other)) == "")
    }
}
