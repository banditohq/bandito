import BanditoKit
import Foundation

// MARK: - E: subscriptions

/// Where one agent CLI stands for this person: not on the server, not signed in, signed in (with its plan),
/// or signed in as far as the person says so (the server cannot tell, e.g. for Grok).
enum SubscriptionState: Equatable, Sendable {
    case notInstalled
    case needsLogin
    /// Installed, but the server does not report the login. The person confirms it with "Done".
    case unverified
    case loggedIn(plan: String?)

    /// The server reports the login, or the person confirmed it.
    var isReady: Bool {
        if case .loggedIn = self { return true }
        return false
    }

    /// `loggedIn` is the server's answer (nil when it does not say); `confirmed` is the person's "Done".
    static func resolve(installed: Bool, loggedIn: Bool?, plan: String?, confirmed: Bool) -> SubscriptionState {
        guard installed else { return .notInstalled }
        switch loggedIn {
        case .some(true): return .loggedIn(plan: plan)
        case .some(false): return confirmed ? .loggedIn(plan: plan) : .needsLogin
        case .none: return confirmed ? .loggedIn(plan: plan) : .unverified
        }
    }
}

/// The address a login terminal printed, to open in the browser. Only https is ever offered.
enum LoginLink {
    private static let pattern = #"https?://[^\s"'<>\u{1B}]+"#
    private static let ansi = #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#

    /// The last https link in `text` (terminal colour codes removed). Trailing punctuation is not part of it.
    static func lastHTTPS(in text: String) -> URL? {
        let plain = text.replacingOccurrences(of: ansi, with: "", options: .regularExpression)
        let matches = plain.matches(of: try! Regex(pattern))
        for match in matches.reversed() {
            let raw = String(plain[match.range])
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>'\""))
            if let url = URL(string: trimmed), url.scheme == "https", url.host != nil {
                return url
            }
        }
        return nil
    }
}

/// The command that starts the login of one agent CLI. The first line of the terminal says what to do next.
enum LoginCommand {
    static func arguments(for runtime: RuntimeKind) -> [String] {
        switch runtime {
        case .claude: ["claude"]
        case .codex: ["codex", "login"]
        case .grok: ["grok", "login", "--device-auth"]
        case .api: []
        }
    }
}

// MARK: - F: first agent

enum AgentNameRule {
    enum Problem: Equatable {
        case empty
        case tooLong
        case badCharacters
        case duplicate
    }

    static let maxLength = 40

    /// The problem with `name`, or nil when it can be used. Names compare without case against `existing`.
    static func problem(for name: String, existing: [String]) -> Problem? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        guard trimmed.count <= maxLength else { return .tooLong }
        let allowed = trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        guard allowed else { return .badCharacters }
        if existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .duplicate
        }
        return nil
    }
}

enum AgentRuntimeChoice {
    private static let order: [RuntimeKind] = [.claude, .codex, .grok]

    /// The template's runtime when it is signed in, otherwise the first signed-in one. Nil when none is.
    static func pick(preferred: RuntimeKind, signedIn: [RuntimeKind]) -> RuntimeKind? {
        if signedIn.contains(preferred) { return preferred }
        return order.first { signedIn.contains($0) }
    }
}

enum AgentFolder {
    /// `<home>/projects/<slug of the name>`. A name with no letters or digits becomes `agent`.
    static func defaultPath(home: String, name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
            } else if (character == " " || character == "-" || character == "_"), !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "agent" }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return "\(base)/projects/\(slug)"
    }
}

// MARK: - tour

/// The things the tour points at, in the order it shows them.
enum TourAnchor: CaseIterable, Sendable {
    case agents, composer, approvals, quickOpen, modes
}

enum TourPlan {
    /// The steps that have their anchor on screen, in tour order.
    static func steps(available: Set<TourAnchor>) -> [TourAnchor] {
        TourAnchor.allCases.filter { available.contains($0) }
    }
}

/// Position in the tour. Finished when past the last step, or at once when there are no steps.
struct TourModel: Equatable {
    private(set) var steps: [TourAnchor]
    private(set) var index = 0

    init(steps: [TourAnchor]) {
        self.steps = steps
    }

    var current: TourAnchor? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    var isLast: Bool {
        index == steps.count - 1
    }

    var isFinished: Bool {
        index >= steps.count
    }

    mutating func next() {
        index += 1
    }

    /// "Skip": the tour ends here, whatever step it is on.
    mutating func skip() {
        index = steps.count
    }
}
