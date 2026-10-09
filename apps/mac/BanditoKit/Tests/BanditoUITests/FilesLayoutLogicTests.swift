@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Pure layout rules of the Files browser: how the path trail folds, which columns show, and the widths at
/// which the search, the details panel, and the labels change.
@Suite struct FilesLayoutLogicTests {
    static func entry(_ name: String, dir: Bool) -> FsEntry {
        FsEntry(
            name: name, path: "/w/\(name)", kind: dir ? .dir : .file, size: 10, modifiedMs: 0,
            hidden: false, readonly: false, symlinkTarget: nil, ext: nil)
    }

    // MARK: Path trail

    @Test func shortTrailShowsEverySegment() {
        let layouts = CrumbTrail.layouts(count: 3)
        #expect(layouts.first == [.crumb(0), .crumb(1), .crumb(2)])
    }

    @Test func longTrailFoldsMiddleSegmentsIntoAnOverflowAndKeepsTheEnds() {
        let layouts = CrumbTrail.layouts(count: 6)
        #expect(layouts.count == 3)
        #expect(layouts[0] == (0..<6).map { CrumbTrailItem.crumb($0) })
        #expect(layouts[1] == [.crumb(0), .overflow([1, 2, 3]), .crumb(4), .crumb(5)])
        #expect(layouts[2] == [.overflow([0, 1, 2, 3, 4]), .crumb(5)])
    }

    @Test func narrowestTrailKeepsOnlyTheLastSegment() {
        for count in 1...8 {
            let layouts = CrumbTrail.layouts(count: count)
            #expect(layouts.count == 3)
            #expect(layouts[2].last == .crumb(count - 1))
        }
    }

    @Test func emptyTrailHasNoLayouts() {
        #expect(CrumbTrail.layouts(count: 0) == [[], [], []])
    }

    // MARK: Columns

    @Test func sizeColumnShowsOnlyWhenSomeEntryIsAFile() {
        #expect(!FileColumns.showsSize([Self.entry("src", dir: true), Self.entry("tests", dir: true)]))
        #expect(FileColumns.showsSize([Self.entry("src", dir: true), Self.entry("a.txt", dir: false)]))
        #expect(!FileColumns.showsSize([]))
    }

    // MARK: Widths

    @Test func detailsPanelIsDockedOnlyWhenTheWindowIsWideEnough() {
        #expect(!FileBrowserLayout.isPanelDocked(windowWidth: 1179))
        #expect(FileBrowserLayout.isPanelDocked(windowWidth: 1180))
        #expect(FileBrowserLayout.isPanelDocked(windowWidth: 1920))
    }
}
