import AppKit
import BanditoKit
import BanditoL10n
import Foundation
import Observation
import UserNotifications

/// The app side of telemetry: the first-run notice, the crash-report question, the pulse schedule and the strip of
/// announcements. The rules live in BanditoKit (`Telemetry`, `CrashCheckRules`, `AnnouncementRules`); this model runs
/// them and keeps what the screens show.
@MainActor
@Observable
public final class TelemetryCenter {
    /// The first-run notice about statistics: once after the update, until the person answers it.
    public private(set) var showsNotice: Bool
    /// The question about crash reports, asked once when a new report is found and no answer exists yet.
    public private(set) var showsCrashQuestion = false
    /// The announcement on the strip at the top of the main window, if one is due.
    public private(set) var banner: Announcement?
    /// Mirrors of the consent, so the Privacy section updates at once.
    public private(set) var statsEnabled: Bool
    public private(set) var crashReports: Bool

    @ObservationIgnored private let telemetry: Telemetry
    /// Announcements from the last pulse that were not shown yet (the order of the server).
    @ObservationIgnored private var queue: [Announcement] = []

    public init(telemetry: Telemetry = .shared) {
        self.telemetry = telemetry
        // The install id is made on the first launch, not on the first send.
        _ = telemetry.installID
        showsNotice = !telemetry.hasSeenNotice
        statsEnabled = telemetry.statsEnabled
        crashReports = telemetry.crashReports == true
    }

    /// The privacy policy, on the site (the same page in all nine languages).
    public static let privacyPolicyURL = URL(string: "https://bandito.dev/privacy")!

    // MARK: consent

    /// "OK" keeps statistics on; "Don't send" turns them off, which also erases what was counted.
    public func answerNotice(sendStatistics: Bool) {
        telemetry.markNoticeSeen()
        setStatistics(sendStatistics)
        showsNotice = false
    }

    public func setStatistics(_ on: Bool) {
        telemetry.statsEnabled = on
        statsEnabled = on
    }

    public func setCrashReports(_ on: Bool) {
        telemetry.setCrashReports(on)
        crashReports = on
    }

    /// Answer to the crash question. A yes sends the reports found; a no remembers them without sending.
    public func answerCrashQuestion(send: Bool) async {
        showsCrashQuestion = false
        setCrashReports(send)
        await checkCrashReports()
    }

    /// "Delete my data": the server forgets this install, then a new install id starts. Throws on failure, and then
    /// nothing changed.
    public func deleteData() async throws {
        try await telemetry.forget()
    }

    // MARK: launch and schedule

    /// Connects the session token of the account (the pulse and `forget` send it only when someone is signed in).
    public func attach(accountHub hub: AccountHub) {
        telemetry.setSessionToken { await Self.sessionToken(from: hub) }
    }

    @MainActor
    private static func sessionToken(from hub: AccountHub) async -> String? {
        guard hub.signedIn, let client = try? await hub.prepare() else { return nil }
        return try? await client.restoreSession()?.token
    }

    /// Runs for the life of the window: the crash check at once, then the pulse 30 seconds after the launch and every
    /// 24 hours. QA copies send nothing. Cancelled with the window.
    public func run(app: AppModel) async {
        guard QABuild.index(bundleID: Bundle.main.bundleIdentifier) == nil else { return }
        await checkCrashReports()
        try? await Task.sleep(for: .seconds(30))
        while !Task.isCancelled {
            await sendPulse(app: app)
            try? await Task.sleep(for: .seconds(24 * 60 * 60))
        }
    }

    /// Sends the pulse now and takes the announcements of the answer.
    public func sendPulse(app: AppModel) async {
        let facts = await PulseFactsCollector.facts(
            servers: app.servers, client: Self.clientInfo, lang: Self.languageCode,
            region: Locale.current.region?.identifier)
        guard let list = await telemetry.sendPulse(facts: facts) else { return }
        queue = list
        showNextBanner()
    }

    // MARK: crash reports

    /// Finds the reports written since the last check and does what `CrashCheckRules` says.
    public func checkCrashReports() async {
        let reports = CrashReportScanner.reports(
            in: CrashReportScanner.defaultDirectory, modifiedAfter: telemetry.crashSeenAt)
        switch CrashCheckRules.plan(reports: reports, seenAt: telemetry.crashSeenAt, consent: telemetry.crashReports) {
        case .baseline:
            telemetry.crashSeenAt = Date()
        case .ask:
            showsCrashQuestion = true
        case .skip(let until):
            if let until { telemetry.crashSeenAt = until }
        case .send(let files):
            var handled: Date?
            for file in files {
                // A report that does not parse is passed over; a failed send stops here, so it is tried again later.
                if let data = try? Data(contentsOf: file.url), let summary = CrashReportParser.summary(from: data) {
                    guard await telemetry.sendCrash(summary, client: Self.clientInfo) else { break }
                }
                handled = file.modified
            }
            if let handled { telemetry.crashSeenAt = handled }
        }
    }

    // MARK: announcements

    /// The strip shows the next announcement that is due and was not shown on this Mac before.
    private func showNextBanner() {
        guard banner == nil,
            let next = AnnouncementRules.next(queue, isShown: telemetry.isShown, now: Date())
        else { return }
        telemetry.markShown(next.id)
        banner = next
        queue.removeAll { $0.id == next.id }
        if next.level == .system { postSystemNotification(next) }
        event(.shown, for: next)
    }

    /// The strip's close button.
    public func dismissBanner() {
        guard let shown = banner else { return }
        banner = nil
        event(.dismissed, for: shown)
        showNextBanner()
    }

    /// The strip's button: opens the https link and counts the click.
    public func openBannerLink() {
        guard let shown = banner, let url = shown.url else { return }
        NSWorkspace.shared.open(url)
        banner = nil
        event(.clicked, for: shown)
        showNextBanner()
    }

    private func event(_ kind: AnnouncementEvent, for announcement: Announcement) {
        let telemetry = self.telemetry
        Task { await telemetry.sendAnnouncementEvent(id: announcement.id, event: kind) }
    }

    /// A macOS notification for a `system` announcement, when the person allowed notifications. It is not asked for
    /// here: the permission belongs to Settings → Notifications.
    private func postSystemNotification(_ announcement: Announcement) {
        let center = UNUserNotificationCenter.current()
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = announcement.title
            content.body = announcement.body
            let request = UNNotificationRequest(
                identifier: "bandito.announcement.\(announcement.id)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    // MARK: what the pulse says about the app

    /// The app's version, build, system and architecture, from the bundle and the system.
    static var clientInfo: ClientInfo {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Int(info?["CFBundleVersion"] as? String ?? "") ?? 0
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = os.patchVersion > 0
            ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            : "\(os.majorVersion).\(os.minorVersion)"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return ClientInfo(app: version, build: build, os: osText, arch: arch)
    }

    /// The interface language code (`ru`, `zh-Hans`): the language the bundle actually shows.
    static var languageCode: String {
        L10n.bundle.preferredLocalizations.first ?? "en"
    }
}

extension AppMode {
    /// The counter of this section. The server and the menu of this Mac have none.
    var telemetryScreen: TelemetryEvent.Screen? {
        switch self {
        case .team: .team
        case .market: .market
        case .terminals: .terminals
        case .files: .files
        case .browser: .browser
        case .screen, .server: nil
        }
    }
}
