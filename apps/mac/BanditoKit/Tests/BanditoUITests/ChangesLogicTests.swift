import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoL10n
@testable import BanditoUI

/// Pure logic behind the "What changed" sheet: unified diff parsing, side-by-side pairs, partial rollback
/// selection, restore points and their captions.
@MainActor
@Suite struct ChangesLogicTests {
    /// Two hunks: a change inside the first, and a removed line whose text starts with "--".
    static let unified: [String] = [
        "diff --git a/src/x.rs b/src/x.rs",
        "index 1111111..2222222 100644",
        "--- a/src/x.rs",
        "+++ b/src/x.rs",
        "@@ -1,4 +1,5 @@ fn a() {",
        " fn a() {",
        "-    let x = 1;",
        "+    let x = 10;",
        "     let y = 2;",
        "+    let z = 3;",
        " }",
        "@@ -20,2 +21,2 @@",
        "--- old comment",
        "+-- new comment",
        " tail",
        "\\ No newline at end of file",
    ]

    static func text(_ lines: [String]) -> String { lines.joined(separator: "\n") }

    // MARK: - Unified diff

    @Test func parsesHunksAndNumbersEveryLine() {
        let hunks = UnifiedDiff.parse(Self.text(Self.unified))
        #expect(hunks.count == 2)
        #expect(hunks[0].header == "@@ -1,4 +1,5 @@ fn a() {")
        #expect(hunks[0].oldStart == 1)
        #expect(hunks[0].newStart == 1)
        #expect(
            hunks[0].lines == [
                ChangeLine(kind: .context, oldNumber: 1, newNumber: 1, text: "fn a() {"),
                ChangeLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "    let x = 1;"),
                ChangeLine(kind: .added, oldNumber: nil, newNumber: 2, text: "    let x = 10;"),
                ChangeLine(kind: .context, oldNumber: 3, newNumber: 3, text: "    let y = 2;"),
                ChangeLine(kind: .added, oldNumber: nil, newNumber: 4, text: "    let z = 3;"),
                ChangeLine(kind: .context, oldNumber: 4, newNumber: 5, text: "}"),
            ])
    }

    @Test func removedLineStartingWithDashesStaysRemoved() {
        let hunks = UnifiedDiff.parse(Self.text(Self.unified))
        #expect(hunks[1].oldStart == 20)
        #expect(hunks[1].newStart == 21)
        #expect(hunks[1].lines.count == 3)
        #expect(hunks[1].lines[0] == ChangeLine(kind: .removed, oldNumber: 20, newNumber: nil, text: "-- old comment"))
        #expect(hunks[1].lines[1] == ChangeLine(kind: .added, oldNumber: nil, newNumber: 21, text: "-- new comment"))
        #expect(hunks[1].lines[2] == ChangeLine(kind: .context, oldNumber: 21, newNumber: 22, text: "tail"))
    }

    @Test func emptyTextHasNoHunks() {
        #expect(UnifiedDiff.parse("").isEmpty)
    }

    // MARK: - Side by side

    @Test func sideBySidePairsRemovedWithAddedAndKeepsContext() {
        let rows = SideBySide.rows(from: UnifiedDiff.parse(Self.text(Self.unified)))
        // Hunk 1: header and 5 rows. Hunk 2: header, a changed pair and a context pair.
        #expect(rows.count == 9)
        #expect(rows[0] == .hunk("@@ -1,4 +1,5 @@ fn a() {"))
        #expect(
            rows[2]
                == .pair(
                    left: SideCell(number: 2, text: "    let x = 1;", kind: .removed),
                    right: SideCell(number: 2, text: "    let x = 10;", kind: .added)))
        #expect(
            rows[4]
                == .pair(
                    left: nil,
                    right: SideCell(number: 4, text: "    let z = 3;", kind: .added)))
        #expect(
            rows[5]
                == .pair(
                    left: SideCell(number: 4, text: "}", kind: .context),
                    right: SideCell(number: 5, text: "}", kind: .context)))
    }

    @Test func extraRemovedLinesGetEmptyRightSide() {
        let hunk = ChangeHunk(
            header: "@@ -1,2 +1,1 @@", oldStart: 1, newStart: 1,
            lines: [
                ChangeLine(kind: .removed, oldNumber: 1, newNumber: nil, text: "a"),
                ChangeLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "b"),
                ChangeLine(kind: .added, oldNumber: nil, newNumber: 1, text: "c"),
            ])
        let rows = SideBySide.rows(from: [hunk])
        #expect(
            rows == [
                .hunk("@@ -1,2 +1,1 @@"),
                .pair(
                    left: SideCell(number: 1, text: "a", kind: .removed),
                    right: SideCell(number: 1, text: "c", kind: .added)),
                .pair(left: SideCell(number: 2, text: "b", kind: .removed), right: nil),
            ])
    }

    // MARK: - Partial rollback

    static let files: [FileChange] = [
        FileChange(path: "src/webhook.rs", status: .modified, from: nil, additions: 86, deletions: 4),
        FileChange(path: "README.md", status: .modified, from: nil, additions: 7, deletions: 3),
        FileChange(path: "src/new.rs", status: .renamed, from: "src/old.rs", additions: 0, deletions: 0),
    ]

    @Test func everythingKeptRollsBackNothing() {
        let keep = Set(Self.files.map(\.id))
        #expect(RollbackPlan.paths(files: Self.files, keep: keep).isEmpty)
    }

    @Test func unticketedFileIsRestored() {
        let keep: Set<String> = ["src/webhook.rs", "src/new.rs"]
        #expect(RollbackPlan.paths(files: Self.files, keep: keep) == ["README.md"])
    }

    @Test func unticketedRenameRestoresBothPaths() {
        let keep: Set<String> = ["src/webhook.rs", "README.md"]
        #expect(RollbackPlan.paths(files: Self.files, keep: keep) == ["src/new.rs", "src/old.rs"])
    }

    @Test func noFilesKeptRestoresAllOfThem() {
        let paths = RollbackPlan.paths(files: Self.files, keep: [])
        #expect(paths == ["src/webhook.rs", "README.md", "src/new.rs", "src/old.rs"])
    }

    @Test func firstChangedLineIsTheFirstNonContextLine() {
        let hunks = UnifiedDiff.parse(Self.text(Self.unified))
        #expect(ChangeFocus.firstChangedLine(in: hunks) == 2)
        #expect(ChangeFocus.firstChangedLine(in: []) == nil)
    }

    // MARK: - Restore points

    static func checkpoint(_ id: String, _ kind: CheckpointKind, _ label: String) -> Checkpoint {
        Checkpoint(id: id, sha: "sha-\(id)", label: label, kind: kind, turnId: nil, createdAt: 1)
    }

    /// Newest first, as the daemon returns them.
    static let history: [Checkpoint] = [
        checkpoint("c5", .after, "after"),
        checkpoint("c4", .before, "before: second task"),
        checkpoint("c3", .after, "after"),
        checkpoint("c2", .before, "before: first task"),
        checkpoint("c1", .after, "after"),
    ]

    @Test func baseIsTheNewestBeforeCheckpoint() {
        #expect(RestorePoints.base(in: Self.history)?.id == "c4")
        #expect(RestorePoints.base(in: [Self.checkpoint("a", .after, "after")]) == nil)
    }

    @Test func timelineRunsFromTheBaseToNewest() {
        #expect(RestorePoints.timeline(Self.history).map(\.id) == ["c4", "c5"])
        #expect(RestorePoints.timeline([]).isEmpty)
    }

    // MARK: - Captions

    @Test func beforeCaptionDropsThePrefix() {
        let cp = Self.checkpoint("c", .before, "before: fix the webhook tests")
        #expect(CheckpointLabel.task(for: cp) == "fix the webhook tests")
        #expect(CheckpointLabel.text(for: cp) == "fix the webhook tests")
    }

    @Test func emptyBeforeCaptionFallsBackToStart() {
        let cp = Self.checkpoint("c", .before, "before: ")
        #expect(CheckpointLabel.task(for: cp) == nil)
        #expect(CheckpointLabel.text(for: cp) == L10n.Changes.Point.start)
    }

    @Test func afterAndRestoreCaptionsComeFromTheKind() {
        let after = Self.checkpoint("a", .after, "after")
        let restore = Self.checkpoint("r", .restore, "before restore")
        #expect(CheckpointLabel.task(for: after) == nil)
        #expect(CheckpointLabel.text(for: after) == L10n.Changes.Point.turnEnd)
        #expect(CheckpointLabel.text(for: restore) == L10n.Changes.Point.restore)
    }

    @Test func plusAndMinusAreSummedAcrossFilesWithoutBinaries() {
        // Sums are computed in ChangesDiff (BanditoKit); the sheet header shows them as they are.
        let diff = ChangesDiff(
            from: "c4", to: nil,
            files: [
                FileChange(path: "a.rs", status: .modified, from: nil, additions: 86, deletions: 4),
                FileChange(path: "logo.png", status: .added, from: nil, additions: nil, deletions: nil),
                FileChange(path: "b.rs", status: .deleted, from: nil, additions: 0, deletions: 11),
            ])
        #expect(diff.additions == 86)
        #expect(diff.deletions == 15)
    }
}
