import Foundation
import Testing

@testable import BanditoKit

@Suite struct CrashCheckRulesTests {
    private let seen = Date(timeIntervalSince1970: 1_000)
    private func report(_ name: String, _ at: TimeInterval) -> CrashReportFile {
        CrashReportFile(url: URL(fileURLWithPath: "/tmp/\(name)"), modified: Date(timeIntervalSince1970: at))
    }

    @Test func firstCheckOnlySetsTheBaseline() {
        let plan = CrashCheckRules.plan(reports: [report("Bandito-a.ips", 2_000)], seenAt: nil, consent: nil)
        #expect(plan == .baseline)
    }

    @Test func noNewReportsChangesNothing() {
        #expect(CrashCheckRules.plan(reports: [], seenAt: seen, consent: nil) == .skip(until: nil))
        #expect(CrashCheckRules.plan(reports: [], seenAt: seen, consent: true) == .skip(until: nil))
    }

    @Test func unansweredConsentAsksAndRemembersNothing() {
        let plan = CrashCheckRules.plan(reports: [report("Bandito-a.ips", 2_000)], seenAt: seen, consent: nil)
        #expect(plan == .ask)
    }

    @Test func declinedConsentRemembersTheNewestWithoutSending() {
        let reports = [report("Bandito-a.ips", 2_000), report("Bandito-b.ips", 3_000)]
        let plan = CrashCheckRules.plan(reports: reports, seenAt: seen, consent: false)
        #expect(plan == .skip(until: Date(timeIntervalSince1970: 3_000)))
    }

    @Test func consentSendsTheReportsOldestFirst() {
        let reports = [report("Bandito-a.ips", 2_000), report("Bandito-b.ips", 3_000)]
        let plan = CrashCheckRules.plan(reports: reports, seenAt: seen, consent: true)
        #expect(plan == .send(reports))
    }
}
