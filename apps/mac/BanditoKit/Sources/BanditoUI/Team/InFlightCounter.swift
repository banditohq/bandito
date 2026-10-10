/// How many requests a screen has in flight. While one is, the screen keeps the values it shows and does not take the
/// agent's: a late answer from the daemon would otherwise undo a choice the person has just made.
struct InFlightCounter: Equatable {
    private(set) var count = 0

    var isIdle: Bool { count == 0 }

    mutating func begin() {
        count += 1
    }

    mutating func end() {
        count = max(0, count - 1)
    }
}
