import Foundation

/// The app's identity as the server sees it: version, build, system and architecture. No device name, no account.
public struct ClientInfo: Equatable, Sendable {
    public var app: String
    public var build: Int
    public var os: String
    public var arch: String

    public init(app: String, build: Int, os: String, arch: String) {
        self.app = app
        self.build = build
        self.os = os
        self.arch = arch
    }
}

/// One saved server, from what `daemon.info` already says. Never its address, name or host.
public struct PulseServer: Codable, Equatable, Sendable {
    public var os: String
    public var arch: String
    public var daemon: String

    public init(os: String, arch: String, daemon: String) {
        self.os = os
        self.arch = arch
        self.daemon = daemon
    }
}

/// What the pulse reports about this Mac right now. Built by the app from values it already has.
public struct PulseFacts: Equatable, Sendable {
    public var client: ClientInfo
    /// The interface language code (`en`, `ru`, `zh-Hans`).
    public var lang: String
    /// The region of the system locale (`RU`), never from an IP address.
    public var region: String?
    public var servers: [PulseServer]
    /// Agents of all servers together. Sent only as a bucket.
    public var agentCount: Int
    /// The environments the agents run in (`claude`, `codex`, `grok`, `api`).
    public var runtimes: [String]
    /// A Telegram bot is saved and at least one chat is linked.
    public var telegram: Bool

    public init(
        client: ClientInfo, lang: String, region: String?, servers: [PulseServer], agentCount: Int,
        runtimes: [String], telegram: Bool
    ) {
        self.client = client
        self.lang = lang
        self.region = region
        self.servers = servers
        self.agentCount = agentCount
        self.runtimes = runtimes
        self.telegram = telegram
    }
}

/// The number of agents as a bucket, so the exact count never leaves the Mac.
public enum AgentsBucket: String, Equatable, Sendable {
    case zero = "0"
    case one = "1"
    case twoToFive = "2-5"
    case sixToTwenty = "6-20"
    case moreThanTwenty = "20+"

    public static func bucket(for count: Int) -> AgentsBucket {
        switch count {
        case ..<1: .zero
        case 1: .one
        case 2...5: .twoToFive
        case 6...20: .sixToTwenty
        default: .moreThanTwenty
        }
    }
}

/// The body of `POST /telemetry/pulse` (the wire names are snake_case, see `TelemetryWire`).
public struct PulseBody: Codable, Equatable, Sendable {
    public var installID: String
    public var app: String
    public var build: Int
    public var os: String
    public var arch: String
    public var lang: String
    public var region: String?
    public var servers: [PulseServer]
    public var agentsBucket: String
    public var runtimes: [String]
    public var telegram: Bool
    public var counters: [String: Int]
    public var day: String
}

/// Builds the pulse. Every limit of the contract is applied here, so a caller cannot send too much.
public enum TelemetryPulse {
    public static let maxServers = 10
    public static let maxCounterNames = 100
    public static let maxCounterValue = 100_000

    public static func body(
        installID: String, facts: PulseFacts, counters: [String: Int], day: String
    ) -> PulseBody {
        PulseBody(
            installID: installID,
            app: facts.client.app,
            build: facts.client.build,
            os: facts.client.os,
            arch: facts.client.arch,
            lang: facts.lang,
            region: facts.region,
            servers: Array(facts.servers.prefix(maxServers)),
            agentsBucket: AgentsBucket.bucket(for: facts.agentCount).rawValue,
            runtimes: Array(Set(facts.runtimes)).sorted(),
            telegram: facts.telegram,
            counters: clamped(counters),
            day: day)
    }

    /// Only the names of the whitelist, only positive counts, at most `maxCounterNames` names (sorted, so the
    /// same input always gives the same payload), each count at most `maxCounterValue`.
    static func clamped(_ counters: [String: Int]) -> [String: Int] {
        let kept = counters
            .filter { TelemetryEvent.isAllowedName($0.key) && $0.value > 0 }
            .sorted { $0.key < $1.key }
            .prefix(maxCounterNames)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, min($0.value, maxCounterValue)) })
    }

    /// The UTC calendar day of `date` as `yyyy-MM-dd`. The server keeps its aggregates per this day.
    public static func day(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", Int32(parts.year ?? 1970), Int32(parts.month ?? 1), Int32(parts.day ?? 1))
    }
}

/// JSON for the telemetry API: snake_case on the wire, camelCase in Swift. A new encoder and decoder per call, so
/// nothing shared is mutated.
enum TelemetryWire {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
