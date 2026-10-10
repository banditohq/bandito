@testable import BanditoKit
import Testing

@testable import BanditoUI

/// The memory viewer: when save shows, and the order of a folder's list.
@Suite struct MemoryViewerRulesTests {
    private func entry(_ name: String, dir: Bool = false) -> FsEntry {
        FsEntry(
            name: name, path: "/m/\(name)", kind: dir ? .dir : .file, size: 0, modifiedMs: 0,
            hidden: false, readonly: false, symlinkTarget: nil, ext: nil)
    }

    @Test func saveShowsOnlyForChangesInTheViewer() {
        #expect(MemoryViewerRules.showsSave(isDirty: true, readOnly: false, showingViewer: true))
        #expect(!MemoryViewerRules.showsSave(isDirty: false, readOnly: false, showingViewer: true))
        #expect(!MemoryViewerRules.showsSave(isDirty: true, readOnly: true, showingViewer: true))
        #expect(!MemoryViewerRules.showsSave(isDirty: true, readOnly: false, showingViewer: false))
    }

    @Test func foldersComeFirstThenFilesByName() {
        let sorted = MemoryViewerRules.sortedForList([
            entry("b.md"), entry("notes", dir: true), entry("a.md"), entry("journal", dir: true),
        ])
        #expect(sorted.map(\.name) == ["journal", "notes", "a.md", "b.md"])
    }
}
