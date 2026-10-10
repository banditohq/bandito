import BanditoKit
import Foundation

/// What the person chose on the import screen, and what each choice comes to: which items are taken, under which
/// names, and which names are in the way. Pure, so the rules (conflicts, renames, limits) are easy to test.
struct ImportPlan: Equatable {
    /// What to do with an item whose name is taken.
    enum Resolution: Equatable {
        /// Import under its own name.
        case keep
        /// Import under this name.
        case rename(String)
        /// Leave it.
        case skip
    }

    struct Row: Identifiable, Equatable {
        var item: ImportItem
        var selected: Bool
        var resolution: Resolution = .keep
        var id: String { item.id }
    }

    /// Why a typed name cannot be used.
    enum NameProblem: Equatable {
        case empty
        case tooLong
        case badCharacters
    }

    /// What an item comes to.
    enum State: Equatable {
        case notSelected
        case skippedByYou
        /// Goes in under this name.
        case ready(String)
        /// This name is taken, here or on the server, and the item has not been renamed or skipped yet.
        case conflict(String)
        case invalid(String, NameProblem)
    }

    /// What the server already has.
    struct Existing: Equatable {
        /// Agent names; compared without case.
        var agents: [String] = []
        /// Names of the commands and the skills of the server user's home.
        var commands: Set<String> = []
        var skills: Set<String> = []
    }

    var rows: [Row]
    var existing: Existing

    /// All found items selected, and the conflicts settled with a suggested new name.
    init(items: [ImportItem], existing: Existing = Existing()) {
        rows = items.map { Row(item: $0, selected: true) }
        self.existing = existing
        settle()
    }

    // MARK: changes

    mutating func setSelected(_ id: String, _ on: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].selected = on
        settle()
    }

    mutating func setSelected(kind: ImportKind, _ on: Bool) {
        for index in rows.indices where rows[index].item.kind == kind { rows[index].selected = on }
        settle()
    }

    mutating func setResolution(_ id: String, _ resolution: Resolution) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].resolution = resolution
        settle()
    }

    /// What the server has changed (read again, or read late).
    mutating func setExisting(_ existing: Existing) {
        self.existing = existing
        settle()
    }

    /// Adds the items of another folder; those already there (the same file) are not added twice.
    mutating func add(_ items: [ImportItem]) {
        let known = Set(rows.map(\.id))
        rows += items.filter { !known.contains($0.id) }.map { Row(item: $0, selected: true) }
        settle()
    }

    /// An item that has a taken name and no decision yet is renamed to a free one. Idempotent: what is decided stays.
    private mutating func settle() {
        for index in rows.indices {
            guard case .conflict(let name) = states()[index], rows[index].resolution == .keep else { continue }
            let taken = takenBefore(index)
            rows[index].resolution = .rename(Self.freeName(name, kind: rows[index].item.kind, taken: taken))
        }
    }

    // MARK: states

    func state(of row: Row) -> State {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return .notSelected }
        return states()[index]
    }

    /// The state of every row, in order. A name taken by an earlier row of the batch is taken too.
    func states() -> [State] {
        var takenAgents = Set(existing.agents.map { $0.lowercased() })
        var takenCommands = existing.commands
        var takenSkills = existing.skills
        return rows.map { row in
            guard row.selected else { return .notSelected }
            if row.resolution == .skip { return .skippedByYou }
            let name: String
            if case .rename(let new) = row.resolution { name = new.trimmingCharacters(in: .whitespaces) } else { name = row.item.name }
            if let problem = Self.problem(name, kind: row.item.kind) { return .invalid(name, problem) }
            switch row.item.kind {
            case .agent:
                guard takenAgents.insert(name.lowercased()).inserted else { return .conflict(name) }
            case .command:
                guard takenCommands.insert(name).inserted else { return .conflict(name) }
            case .skill:
                guard takenSkills.insert(name).inserted else { return .conflict(name) }
            }
            return .ready(name)
        }
    }

    /// The names of the kind that are taken before row `index`.
    private func takenBefore(_ index: Int) -> Set<String> {
        let kind = rows[index].item.kind
        var taken: Set<String>
        switch kind {
        case .agent: taken = Set(existing.agents.map { $0.lowercased() })
        case .command: taken = existing.commands
        case .skill: taken = existing.skills
        }
        let all = states()
        for earlier in 0..<index where rows[earlier].item.kind == kind {
            if case .ready(let name) = all[earlier] { taken.insert(kind == .agent ? name.lowercased() : name) }
        }
        return taken
    }

    // MARK: names

    static func problem(_ name: String, kind: ImportKind) -> NameProblem? {
        if name.isEmpty { return .empty }
        switch kind {
        case .agent:
            if name.count > ImportAgentParser.maxNameLength { return .tooLong }
            let allowed = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            return allowed ? nil : .badCharacters
        case .skill:
            return isServerSegment(name) ? nil : .badCharacters
        case .command:
            // A name with a colon is a command in a folder: every part is a name.
            let parts = name.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            return parts.allSatisfy(isServerSegment) ? nil : .badCharacters
        }
    }

    /// A name the server's install takes: letters, digits, `_`, `.` and `-`, starting with a letter, a digit or `_`.
    static func isServerSegment(_ segment: String) -> Bool {
        guard let first = segment.first, first.isASCII, first.isLetter || first.isNumber || first == "_" else { return false }
        return MacCommandParser.isValidSegment(segment)
    }

    /// A name that is free: `name-imported`, then `name-imported-2`, `-3`. An agent's name is kept within 32 characters.
    static func freeName(_ name: String, kind: ImportKind, taken: Set<String>) -> String {
        func isTaken(_ candidate: String) -> Bool { taken.contains(kind == .agent ? candidate.lowercased() : candidate) }
        func fit(_ base: String, suffix: String) -> String {
            guard kind == .agent else { return base + suffix }
            return String(base.prefix(ImportAgentParser.maxNameLength - suffix.count)) + suffix
        }
        var candidate = fit(name, suffix: "-imported")
        var number = 2
        while isTaken(candidate) {
            candidate = fit(name, suffix: "-imported-\(number)")
            number += 1
        }
        return candidate
    }

    // MARK: what runs

    /// A thing to create, in the order it is made.
    struct Step: Equatable, Identifiable {
        var item: ImportItem
        var name: String
        var id: String { item.id }
    }

    /// The items that go in: selected, not skipped, with a name that is free and valid.
    var steps: [Step] {
        zip(rows, states()).compactMap { row, state in
            if case .ready(let name) = state { return Step(item: row.item, name: name) }
            return nil
        }
    }

    /// The items the person left out on purpose (selected, then skipped), for the report.
    var skippedByYou: [ImportItem] {
        zip(rows, states()).compactMap { row, state in state == .skippedByYou ? row.item : nil }
    }

    /// Import can start: something goes in, and no chosen item is stuck on a name.
    var canImport: Bool {
        let all = states()
        let stuck = all.contains { state in
            switch state {
            case .conflict, .invalid: true
            default: false
            }
        }
        return !stuck && all.contains { if case .ready = $0 { true } else { false } }
    }

    /// How many items will be made.
    var count: Int { steps.count }
}

/// The server's agents and user commands as the plan needs them.
enum ImportExisting {
    /// Agent names; commands and skills of the server user's home as `commands.list` names them. Without an agent to
    /// ask for, the commands are not known, and a name that is taken is found when the install is refused.
    static func make(agents: [Agent], commands: [AgentCommand]) -> ImportPlan.Existing {
        ImportPlan.Existing(
            agents: agents.map(\.name),
            commands: Set(commands.filter { $0.source == .user }.map(\.name)),
            skills: Set(commands.filter { $0.source == .skill }.map(\.name)))
    }
}
