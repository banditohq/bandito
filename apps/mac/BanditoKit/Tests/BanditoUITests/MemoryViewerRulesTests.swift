@testable import BanditoKit
import Testing

@testable import BanditoUI

/// The memory viewer: the crumbs of a list, and the order of a folder's list.
@Suite struct MemoryViewerRulesTests {
    private func entry(_ name: String, dir: Bool = false) -> FsEntry {
        FsEntry(
            name: name, path: "/m/\(name)", kind: dir ? .dir : .file, size: 0, modifiedMs: 0,
            hidden: false, readonly: false, symlinkTarget: nil, ext: nil)
    }

    @Test func crumbsRunFromTheRootDown() {
        #expect(
            MemoryViewerRules.crumbs(root: "/m/agent", current: "/m/agent/notes/2026/")
                == [
                    .init(name: "agent", path: "/m/agent"),
                    .init(name: "notes", path: "/m/agent/notes"),
                    .init(name: "2026", path: "/m/agent/notes/2026"),
                ])
        #expect(MemoryViewerRules.crumbs(root: "/m/agent", current: "/m/agent") == [.init(name: "agent", path: "/m/agent")])
        #expect(MemoryViewerRules.crumbs(root: "/", current: "/a") == [.init(name: "/", path: "/"), .init(name: "a", path: "/a")])
        // Outside the root: a single crumb, not a broken path.
        #expect(MemoryViewerRules.crumbs(root: "/m/agent", current: "/m/agentx") == [.init(name: "agentx", path: "/m/agentx")])
    }

    @Test func foldersComeFirstThenFilesByName() {
        let sorted = MemoryViewerRules.sortedForList([
            entry("b.md"), entry("notes", dir: true), entry("a.md"), entry("journal", dir: true),
        ])
        #expect(sorted.map(\.name) == ["journal", "notes", "a.md", "b.md"])
    }
}
