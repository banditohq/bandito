import Foundation

/// Whether a line is unchanged, only in the new text, or only in the old text.
enum DiffKind: Sendable, Equatable {
    case same, added, removed
}

struct DiffLine: Equatable, Sendable {
    var kind: DiffKind
    var text: String
}

/// Line-by-line diff (longest common subsequence). Used by the conflict dialog to show what the server
/// changed next to what the user typed.
enum LineDiff {
    /// Above this many cells the table is too big to build; the result then shows every line as changed.
    private static let maxCells = 4_000_000

    static func diff(old: String, new: String) -> [DiffLine] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let n = a.count
        let m = b.count
        guard n * m <= maxCells else {
            return a.map { DiffLine(kind: .removed, text: $0) } + b.map { DiffLine(kind: .added, text: $0) }
        }

        // lcs[i][j] = length of the longest common subsequence of a[i...] and b[j...].
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                result.append(DiffLine(kind: .same, text: a[i]))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(DiffLine(kind: .removed, text: a[i]))
                i += 1
            } else {
                result.append(DiffLine(kind: .added, text: b[j]))
                j += 1
            }
        }
        while i < n {
            result.append(DiffLine(kind: .removed, text: a[i]))
            i += 1
        }
        while j < m {
            result.append(DiffLine(kind: .added, text: b[j]))
            j += 1
        }
        return result
    }
}
