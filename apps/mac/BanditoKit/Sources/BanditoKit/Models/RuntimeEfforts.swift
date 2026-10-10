import Foundation

extension RuntimeKind {
    /// Effort levels this runtime accepts, lowest first. Mirrors `supported_efforts` in daemon/src/rpc/mod.rs.
    public var supportedEfforts: [Effort] {
        switch self {
        case .claude, .api: [.low, .medium, .high, .xhigh, .max]
        case .codex: [.low, .medium, .high, .xhigh]
        case .grok: [.low, .medium, .high]
        }
    }

    /// The level to use instead of `effort`: itself when the runtime offers it, otherwise the highest
    /// level below it that it does offer.
    public func clampedEffort(_ effort: Effort) -> Effort {
        let offered = supportedEfforts
        if offered.contains(effort) { return effort }
        let ordered = Effort.allCases
        guard let index = ordered.firstIndex(of: effort) else { return offered[0] }
        return ordered[..<index].last(where: { offered.contains($0) }) ?? offered[0]
    }
}

extension Effort {
    /// The level in `offered` closest to this one, counted in `Effort` order. A tie goes to the lower level.
    /// Nil when `offered` is empty.
    public func nearest(in offered: [Effort]) -> Effort? {
        let order = Effort.allCases
        let here = order.firstIndex(of: self) ?? 0
        func rank(_ level: Effort) -> (distance: Int, index: Int) {
            let index = order.firstIndex(of: level) ?? 0
            return (abs(index - here), index)
        }
        return offered.min { rank($0) < rank($1) }
    }
}
