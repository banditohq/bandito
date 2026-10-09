import Foundation

/// Direction of a pane move (⌥⌘ arrows).
public enum TerminalDirection: Sendable, Hashable {
    case left, right, up, down
}

/// Where one pane sits in a layout, in units of the whole area (0…1).
public struct TerminalCell: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
}

/// The arrangements of the terminal area. Index `i` of `cells` is the `i`-th pane on screen.
///
/// `mainRight` is 1.35 : 1 wide like the mockup; `grid` is 2×2 and the largest layout.
public enum TerminalLayout: String, CaseIterable, Codable, Sendable {
    case one, cols, mainRight, grid

    public var capacity: Int { cells.count }

    public var cells: [TerminalCell] {
        switch self {
        case .one:
            [TerminalCell(x: 0, y: 0, width: 1, height: 1)]
        case .cols:
            [
                TerminalCell(x: 0, y: 0, width: 0.5, height: 1),
                TerminalCell(x: 0.5, y: 0, width: 0.5, height: 1),
            ]
        case .mainRight:
            {
                let main = 1.35 / 2.35
                return [
                    TerminalCell(x: 0, y: 0, width: main, height: 1),
                    TerminalCell(x: main, y: 0, width: 1 - main, height: 0.5),
                    TerminalCell(x: main, y: 0.5, width: 1 - main, height: 0.5),
                ]
            }()
        case .grid:
            [
                TerminalCell(x: 0, y: 0, width: 0.5, height: 0.5),
                TerminalCell(x: 0.5, y: 0, width: 0.5, height: 0.5),
                TerminalCell(x: 0, y: 0.5, width: 0.5, height: 0.5),
                TerminalCell(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            ]
        }
    }

    /// The smallest layout with room for `count` panes, or `nil` when even the grid is too small.
    public static func next(fitting count: Int) -> TerminalLayout? {
        allCases.first { $0.capacity >= count }
    }

    /// The pane that ⌥⌘ arrow `direction` moves to from pane `index`, or `nil` at the edge.
    /// A candidate lies beyond the current pane's edge in that direction (so a tall pane never counts as
    /// "below" a pane it sits beside). Among those, the closest by centers along the move wins, then the
    /// closest across it; ties keep the layout order.
    public func neighbor(of index: Int, _ direction: TerminalDirection) -> Int? {
        let cells = cells
        guard cells.indices.contains(index) else { return nil }
        let here = cells[index]
        let eps = 1e-9
        var best: (index: Int, primary: Double, across: Double)?
        for (candidate, cell) in cells.enumerated() where candidate != index {
            let primary: Double
            let across: Double
            switch direction {
            case .left:
                guard cell.x + cell.width <= here.x + eps else { continue }
                primary = here.centerX - cell.centerX
                across = abs(here.centerY - cell.centerY)
            case .right:
                guard cell.x >= here.x + here.width - eps else { continue }
                primary = cell.centerX - here.centerX
                across = abs(here.centerY - cell.centerY)
            case .up:
                guard cell.y + cell.height <= here.y + eps else { continue }
                primary = here.centerY - cell.centerY
                across = abs(here.centerX - cell.centerX)
            case .down:
                guard cell.y >= here.y + here.height - eps else { continue }
                primary = cell.centerY - here.centerY
                across = abs(here.centerX - cell.centerX)
            }
            guard primary > eps else { continue }
            if best == nil || primary < best!.primary - 1e-9
                || (abs(primary - best!.primary) <= 1e-9 && across < best!.across - 1e-9)
            {
                best = (candidate, primary, across)
            }
        }
        return best?.index
    }
}
