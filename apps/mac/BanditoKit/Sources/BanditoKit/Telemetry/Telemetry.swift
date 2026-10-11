import Foundation

/// A telemetry request the server did not take. Nothing is changed on this Mac, so the caller can try again later.
public enum TelemetryError: Error, Equatable, Sendable {
    case failed
}

/// What the person did with an announcement, sent to `announcements/event`.
public enum AnnouncementEvent: String, Sendable {
    case shown, dismissed, clicked
}

/// Anonymous statistics, crash reports and announcements, on the Bandito API (`/api/v1/telemetry/*`).
///
/// Everything waits on this Mac until it is sent. Counts are kept per UTC day in UserDefaults; a pulse sends them and
/// subtracts exactly what it sent, so a count made during the request is kept. With statistics off nothing is counted,
/// nothing is sent, and what was counted is erased. Crash reports have their own consent.
public final class Telemetry: @unchecked Sendable {
    // @unchecked: the mutable state (the token provider and the counts in UserDefaults) is read and written under
    // `lock`. The other stored values are constants.
    public static let shared = Telemetry(
        defaults: .standard, http: URLSessionHTTPClient(), baseURL: AccountClient.defaultBaseURL)

    /// Counts one use of a feature in the shared instance.
    public static func count(_ event: TelemetryEvent) {
        shared.count(event)
    }

    /// The counts of this many days are kept at most (the oldest go first when a pulse cannot reach the server).
    static let maxDays = 14
    static let maxShownAnnouncements = 200

    private enum Key {
        static let installID = "telemetry.installID"
        static let statsEnabled = "telemetry.statsEnabled"
        static let noticeSeen = "telemetry.noticeSeen"
        static let crashReports = "telemetry.crashReports"
        static let crashSeenAt = "telemetry.crashSeenAt"
        static let counters = "telemetry.counters"
        static let shownAnnouncements = "telemetry.shownAnnouncements"
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let http: HTTPClient
    private let baseURL: URL
    private var tokenProvider: (@Sendable () async -> String?)?

    public init(
        defaults: UserDefaults, http: HTTPClient, baseURL: URL,
        sessionToken: (@Sendable () async -> String?)? = nil
    ) {
        self.defaults = defaults
        self.http = http
        self.baseURL = baseURL
        self.tokenProvider = sessionToken
    }

    /// Gives the token of the signed-in session. Only the pulse and `forget` send it, to link the install to the
    /// account; crash reports and announcement events never carry it.
    public func setSessionToken(_ provider: (@Sendable () async -> String?)?) {
        lock.withLock { tokenProvider = provider }
    }

    // MARK: install and consent

    /// A random UUID v4 for this install, created on first use. It is not tied to an account.
    public var installID: String {
        lock.withLock {
            if let id = defaults.string(forKey: Key.installID), UUID(uuidString: id) != nil { return id }
            let id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: Key.installID)
            return id
        }
    }

    /// Anonymous statistics. On unless the person turned it off. Turning it off erases the counts.
    public var statsEnabled: Bool {
        get { defaults.object(forKey: Key.statsEnabled) as? Bool ?? true }
        set {
            lock.withLock {
                defaults.set(newValue, forKey: Key.statsEnabled)
                if !newValue { defaults.removeObject(forKey: Key.counters) }
            }
        }
    }

    /// Whether the first-run notice about statistics was shown and answered.
    public var hasSeenNotice: Bool {
        defaults.bool(forKey: Key.noticeSeen)
    }

    public func markNoticeSeen() {
        defaults.set(true, forKey: Key.noticeSeen)
    }

    /// Consent to crash reports: nil until the person was asked, then true or false.
    public var crashReports: Bool? {
        defaults.object(forKey: Key.crashReports) as? Bool
    }

    public func setCrashReports(_ allowed: Bool) {
        defaults.set(allowed, forKey: Key.crashReports)
    }

    /// The modification date of the newest crash report already handled. Nil before the first check.
    public var crashSeenAt: Date? {
        get { (defaults.object(forKey: Key.crashSeenAt) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { defaults.set(newValue?.timeIntervalSince1970, forKey: Key.crashSeenAt) }
    }

    // MARK: counts

    /// Counts one use of `event` on the day of `now`. Does nothing with statistics off.
    public func count(_ event: TelemetryEvent, now: Date = Date()) {
        guard statsEnabled else { return }
        let day = TelemetryPulse.day(for: now)
        lock.withLock {
            var all = loadCounters()
            all[day, default: [:]][event.name, default: 0] += 1
            saveCounters(all)
        }
    }

    /// The counts of `day` that no pulse has delivered yet.
    public func pendingCounters(day: String) -> [String: Int] {
        lock.withLock { loadCounters()[day] ?? [:] }
    }

    private func loadCounters() -> [String: [String: Int]] {
        guard let data = defaults.data(forKey: Key.counters),
            let all = try? JSONDecoder().decode([String: [String: Int]].self, from: data)
        else { return [:] }
        return all
    }

    private func saveCounters(_ all: [String: [String: Int]]) {
        var kept = all.filter { !$0.value.isEmpty }
        for day in kept.keys.sorted().dropLast(Self.maxDays) {
            kept[day] = nil
        }
        if kept.isEmpty {
            defaults.removeObject(forKey: Key.counters)
        } else if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: Key.counters)
        }
    }

    /// Takes away what a pulse delivered. A count made during the request stays.
    private func subtractDelivered(_ delivered: [String: Int], day: String) {
        lock.withLock {
            var all = loadCounters()
            var current = all[day] ?? [:]
            for (name, sent) in delivered {
                let left = (current[name] ?? 0) - sent
                current[name] = left > 0 ? left : nil
            }
            all[day] = current.isEmpty ? nil : current
            saveCounters(all)
        }
    }

    // MARK: pulse

    /// Sends the pulse: one request for each day that has counts, and one for today even when it has none (a
    /// daily presence is what the pulse is for). Stops at the first failure and keeps what was not delivered.
    ///
    /// - Returns: the announcements of the last delivered pulse, or nil when nothing was sent (statistics off, or the
    ///   server did not answer). An empty array means no announcements.
    public func sendPulse(facts: PulseFacts, now: Date = Date()) async -> [Announcement]? {
        guard statsEnabled else { return nil }
        let today = TelemetryPulse.day(for: now)
        let days = lock.withLock { Set(loadCounters().keys) }.union([today]).sorted()
        var latest: [Announcement]?
        for day in days {
            let snapshot = pendingCounters(day: day)
            let body = TelemetryPulse.body(installID: installID, facts: facts, counters: snapshot, day: day)
            guard let data = await post("/telemetry/pulse", body, authenticated: true),
                let list = Announcement.pulseList(from: data)
            else { break }
            subtractDelivered(snapshot, day: day)
            latest = list
        }
        return latest
    }

    // MARK: forget

    /// Deletes this install's data on the server, then forgets the local counts and starts a new install id.
    /// A failed request throws and changes nothing, so the person can try again.
    public func forget() async throws {
        let id = installID
        struct Body: Encodable { let installID: String }
        guard await post("/telemetry/forget", Body(installID: id), authenticated: true) != nil else {
            throw TelemetryError.failed
        }
        lock.withLock {
            defaults.removeObject(forKey: Key.counters)
            defaults.set(UUID().uuidString.lowercased(), forKey: Key.installID)
        }
    }

    // MARK: crash reports and announcements

    /// Sends one crash report. Only with consent; without it nothing is sent and the result is false.
    @discardableResult
    public func sendCrash(_ crash: CrashSummary, client: ClientInfo) async -> Bool {
        guard crashReports == true else { return false }
        struct Body: Encodable {
            let installID: String
            let app: String
            let build: Int
            let os: String
            let arch: String
            let kind: String
            let frames: [String]
        }
        let body = Body(
            installID: installID, app: client.app, build: client.build, os: client.os, arch: client.arch,
            kind: String(crash.kind.prefix(CrashReportParser.maxKindLength)),
            frames: crash.frames.prefix(CrashReportParser.maxFrames).map {
                String(CrashReportParser.scrubbed($0).prefix(CrashReportParser.maxFrameLength))
            })
        return await post("/telemetry/crash", body, authenticated: false) != nil
    }

    /// Tells the server what happened to an announcement. Not sent with statistics off. Not retried: a lost event
    /// only lowers the count.
    public func sendAnnouncementEvent(id: String, event: AnnouncementEvent) async {
        guard statsEnabled else { return }
        struct Body: Encodable {
            let installID: String
            let id: String
            let event: String
        }
        _ = await post(
            "/announcements/event", Body(installID: installID, id: id, event: event.rawValue), authenticated: false)
    }

    /// Whether an announcement was shown before on this Mac (each one is shown once).
    public func isShown(_ id: String) -> Bool {
        (defaults.stringArray(forKey: Key.shownAnnouncements) ?? []).contains(id)
    }

    public func markShown(_ id: String) {
        lock.withLock {
            var ids = defaults.stringArray(forKey: Key.shownAnnouncements) ?? []
            guard !ids.contains(id) else { return }
            ids.append(id)
            defaults.set(Array(ids.suffix(Self.maxShownAnnouncements)), forKey: Key.shownAnnouncements)
        }
    }

    // MARK: transport

    /// POSTs `body` as JSON. Returns the answer body for a 2xx status, nil otherwise. The base URL must be the
    /// Bandito API (`AccountClient.validate`), so the token never goes elsewhere.
    private func post<Body: Encodable>(_ path: String, _ body: Body, authenticated: Bool) async -> Data? {
        guard (try? AccountClient.validate(baseURL: baseURL)) != nil else { return nil }
        var root = baseURL.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        guard let url = URL(string: root + path), let payload = try? TelemetryWire.encode(body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            let provider = lock.withLock { tokenProvider }
            if let token = await provider?() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        do {
            let (data, response) = try await http.send(request)
            guard (200..<300).contains(response.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
