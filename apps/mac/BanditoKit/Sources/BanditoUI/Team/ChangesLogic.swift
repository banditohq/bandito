import BanditoKit
import BanditoL10n
import Foundation

// Logic behind the "What changed" view (ChangesView.swift draws it). Free of views, so it is tested alone.

/// Whether a line of a unified diff is unchanged, only in the new file, or only in the old one.
enum ChangeLineKind: Sendable, Equatable {
    case context, added, removed
}

/// One line of a hunk. It has a number on the side it belongs to: a removed line only `oldNumber`,
/// an added line only `newNumber`, a context line both.
struct ChangeLine: Equatable, Sendable {
    var kind: ChangeLineKind
    var oldNumber: Int?
    var newNumber: Int?
    var text: String
}

/// One `@@` block of a unified diff. `header` is the whole `@@ … @@ …` line.
struct ChangeHunk: Equatable, Sendable {
    var header: String
    var oldStart: Int
    var newStart: Int
    var lines: [ChangeLine]
}

/// Parser for the unified diff that `changes.file` returns (git style, `@@` hunks, 3 lines of context).
enum UnifiedDiff {
    static func parse(_ text: String) -> [ChangeHunk] {
        var hunks: [ChangeHunk] = []
        // Lines still expected in the current hunk on each side. Counting them tells a hunk's body
        // apart from the headers around it, so a removed line that starts with "--" is not mistaken for one.
        var oldLeft = 0
        var newLeft = 0
        var oldLine = 0
        var newLine = 0

        for line in text.components(separatedBy: "\n") {
            if oldLeft == 0 && newLeft == 0 {
                guard let header = parseHeader(line) else { continue }
                hunks.append(ChangeHunk(header: line, oldStart: header.oldStart, newStart: header.newStart, lines: []))
                oldLine = header.oldStart
                newLine = header.newStart
                oldLeft = header.oldCount
                newLeft = header.newCount
                continue
            }

            // The first character is the marker; an empty line is an empty context line.
            let marker: Character? = line.first
            let body = String(line.dropFirst())
            if marker == "\\" {
                // "\ No newline at end of file" describes the line before it; it is not a line.
                continue
            }
            if marker == "+" && newLeft > 0 {
                append(ChangeLine(kind: .added, oldNumber: nil, newNumber: newLine, text: body), to: &hunks)
                newLine += 1
                newLeft -= 1
            } else if marker == "-" && oldLeft > 0 {
                append(ChangeLine(kind: .removed, oldNumber: oldLine, newNumber: nil, text: body), to: &hunks)
                oldLine += 1
                oldLeft -= 1
            } else if (marker == " " || marker == nil) && oldLeft > 0 && newLeft > 0 {
                append(ChangeLine(kind: .context, oldNumber: oldLine, newNumber: newLine, text: body), to: &hunks)
                oldLine += 1
                newLine += 1
                oldLeft -= 1
                newLeft -= 1
            }
        }
        return hunks
    }

    private static func append(_ line: ChangeLine, to hunks: inout [ChangeHunk]) {
        hunks[hunks.count - 1].lines.append(line)
    }

    /// `@@ -a[,b] +c[,d] @@ …`. A missing count means 1.
    private static func parseHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard line.hasPrefix("@@ ") else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 3, fields[1].hasPrefix("-"), fields[2].hasPrefix("+"),
            let old = range(fields[1].dropFirst()), let new = range(fields[2].dropFirst())
        else { return nil }
        return (old.start, old.count, new.start, new.count)
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int)? {
        let parts = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int(parts[0]) else { return nil }
        guard parts.count == 2 else { return (start, 1) }
        guard let count = Int(parts[1]) else { return nil }
        return (start, count)
    }
}

/// One side of a side-by-side row.
struct SideCell: Equatable, Sendable {
    var number: Int
    var text: String
    var kind: ChangeLineKind
}

/// A row of the side-by-side view: a hunk header, or the old line on the left and the new one on the right.
enum SideBySideRow: Equatable, Sendable {
    case hunk(String)
    case pair(left: SideCell?, right: SideCell?)
}

enum SideBySide {
    /// Pairs the lines of each hunk. A block of removed lines followed by added lines is paired one to one;
    /// the leftovers face an empty cell. Context lines sit on both sides.
    static func rows(from hunks: [ChangeHunk]) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        for hunk in hunks {
            rows.append(.hunk(hunk.header))
            var removed: [SideCell] = []
            var added: [SideCell] = []

            func flush() {
                for index in 0..<max(removed.count, added.count) {
                    rows.append(
                        .pair(
                            left: index < removed.count ? removed[index] : nil,
                            right: index < added.count ? added[index] : nil))
                }
                removed.removeAll()
                added.removeAll()
            }

            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    if let cell = cell(line.oldNumber, line.text, .removed) { removed.append(cell) }
                case .added:
                    if let cell = cell(line.newNumber, line.text, .added) { added.append(cell) }
                case .context:
                    flush()
                    rows.append(
                        .pair(
                            left: cell(line.oldNumber, line.text, .context),
                            right: cell(line.newNumber, line.text, .context)))
                }
            }
            flush()
        }
        return rows
    }

    private static func cell(_ number: Int?, _ text: String, _ kind: ChangeLineKind) -> SideCell? {
        guard let number else { return nil }
        return SideCell(number: number, text: text, kind: kind)
    }
}

/// Position of a line inside the hunks of a diff.
struct ChangeLocation: Hashable, Sendable {
    var hunk: Int
    var line: Int
}

enum ChangeFocus {
    /// The first added or removed line, or `nil` when the diff has none.
    static func firstChange(in hunks: [ChangeHunk]) -> ChangeLocation? {
        for (hunkIndex, hunk) in hunks.enumerated() {
            if let lineIndex = hunk.lines.firstIndex(where: { $0.kind != .context }) {
                return ChangeLocation(hunk: hunkIndex, line: lineIndex)
            }
        }
        return nil
    }

    /// The line of the current file that a diff line points at. A removed line is gone from the file, so
    /// it points at the line that now stands where it was. Used for "Ask the agent about this place".
    static func currentLine(in hunks: [ChangeHunk], at location: ChangeLocation) -> Int? {
        guard hunks.indices.contains(location.hunk) else { return nil }
        let hunk = hunks[location.hunk]
        guard hunk.lines.indices.contains(location.line) else { return nil }
        let newSideBefore = hunk.lines[..<location.line].filter { $0.kind != .removed }.count
        return hunk.newStart + newSideBefore
    }

    /// The place to ask about: the given location, else the first change.
    static func placeLine(in hunks: [ChangeHunk], at location: ChangeLocation?) -> Int? {
        guard let target = location ?? firstChange(in: hunks) else { return nil }
        return currentLine(in: hunks, at: target)
    }

    /// Line number of the first change, as `placeLine` gives it for the default location.
    static func firstChangedLine(in hunks: [ChangeHunk]) -> Int? {
        placeLine(in: hunks, at: nil)
    }
}

/// Which files go back on a partial rollback.
enum RollbackPlan {
    /// Files whose "keep" box is unticked, in the order of the diff.
    static func unticked(files: [FileChange], keep: Set<String>) -> [FileChange] {
        files.filter { !keep.contains($0.id) }
    }

    /// Paths to restore for the unticked files. A rename brings back its old path as well.
    /// Empty when everything is kept.
    static func paths(files: [FileChange], keep: Set<String>) -> [String] {
        var paths: [String] = []
        for file in unticked(files: files, keep: keep) {
            for path in [file.path, file.from].compactMap({ $0 }) where !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }
}

/// The restore points the sheet offers. The daemon returns checkpoints newest first.
enum RestorePoints {
    /// The newest `before` checkpoint: the base the sheet compares against by default.
    static func base(in checkpoints: [Checkpoint]) -> Checkpoint? {
        checkpoints.first { $0.kind == .before }
    }

    /// Points from the base to the newest checkpoint, oldest first. Empty when there is no `before`.
    static func timeline(_ checkpoints: [Checkpoint]) -> [Checkpoint] {
        guard let index = checkpoints.firstIndex(where: { $0.kind == .before }) else { return [] }
        return Array(checkpoints[...index].reversed())
    }
}

enum CheckpointLabel {
    private static let beforePrefix = "before: "

    /// The message a turn started from: a `before` label without its prefix. `nil` for other kinds
    /// and for an empty message.
    static func task(for checkpoint: Checkpoint) -> String? {
        guard checkpoint.kind == .before else { return nil }
        let raw =
            checkpoint.label.hasPrefix(beforePrefix)
            ? String(checkpoint.label.dropFirst(beforePrefix.count))
            : checkpoint.label
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Caption of a restore point: the message for `before`, "End of turn" for `after`,
    /// "Before restore" for a restore.
    static func text(for checkpoint: Checkpoint) -> String {
        switch checkpoint.kind {
        case .before: task(for: checkpoint) ?? L10n.Changes.Point.start
        case .after: L10n.Changes.Point.turnEnd
        case .restore: L10n.Changes.Point.restore
        }
    }
}

/// The text of the added and removed line counts in the changes header ("+412", "−18").
enum ChangesChips {
    static func additions(_ count: Int) -> String { "+\(count)" }
    static func deletions(_ count: Int) -> String { "−\(count)" }
}

/// The quiet line under the changes header: "6 файлов · +412 −18". The task follows it in the view.
enum ChangesSummaryLine {
    static func stats(files: Int, additions: Int, deletions: Int) -> String {
        "\(L10n.Changes.fileCount(count: files)) · \(ChangesChips.additions(additions)) \(ChangesChips.deletions(deletions))"
    }
}

/// Footer of the changes panel. Wide: one row (two quiet buttons, the hint, the main button). Narrow: the main
/// button on top, full width, and the two others side by side under it.
enum ChangesFooterLayout {
    /// Below this width the row does not fit with the longest translations and the hint.
    static let rowMinWidth: CGFloat = 680

    static func isStacked(width: CGFloat) -> Bool {
        width < rowMinWidth
    }
}

/// The icon of a changed file: the kind of the file, from its name, as the Files mode draws it.
enum ChangedFileKind {
    static func category(path: String) -> FileCategory {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return FileTypes.category(name: name, ext: URL(fileURLWithPath: name).pathExtension, kind: .file)
    }
}

/// What the window shows after a rollback: how many files came back, and the checkpoint that undoes it.
struct RollbackNotice: Identifiable {
    let id = UUID()
    let server: ServerModel
    let agentID: String
    let count: Int
    let undoCheckpointID: String
}
