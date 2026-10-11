import Foundation
import Testing

@testable import BanditoKit

@Suite struct AnnouncementTests {
    private let pulseReply = """
        {"ok": true, "announcements": [
          {"id": "n-1", "title": "Update", "body": "New version", "url": "https://bandito.dev/news",
           "button": "Read", "level": "banner", "expires_at": "2099-01-01T00:00:00Z"},
          {"id": "n-2", "title": "Plain", "body": "No link", "url": "http://evil.example/x",
           "level": "system", "expires_at": "2099-01-01T00:00:00.500Z"},
          {"id": "n-3", "title": "Bad level", "body": "x", "level": "popup", "expires_at": "2099-01-01T00:00:00Z"},
          {"id": "n-4", "title": "Bad date", "body": "x", "level": "banner", "expires_at": "tomorrow"},
          {"id": "n-5", "title": "Missing body", "level": "banner", "expires_at": "2099-01-01T00:00:00Z"}
        ]}
        """

    @Test func decodesValidItemsAndSkipsBrokenOnes() throws {
        let list = try #require(Announcement.pulseList(from: Data(pulseReply.utf8)))
        #expect(list.map(\.id) == ["n-1", "n-2"])
        #expect(list[0].url?.absoluteString == "https://bandito.dev/news")
        #expect(list[0].button == "Read")
        #expect(list[0].level == .banner)
        #expect(list[1].level == .system)
    }

    @Test func linksAreHTTPSOnly() throws {
        let list = try #require(Announcement.pulseList(from: Data(pulseReply.utf8)))
        #expect(list[1].url == nil)
        #expect(list[1].title == "Plain")
    }

    @Test func notOKReplyGivesNoList() {
        #expect(Announcement.pulseList(from: Data(#"{"ok":false,"error":"rate_limited"}"#.utf8)) == nil)
    }

    @Test func expiredAndShownAreNotPending() {
        let list = [
            Announcement.sample(id: "old", expiresAt: "2020-01-01T00:00:00Z"),
            Announcement.sample(id: "shown", expiresAt: "2099-01-01T00:00:00Z"),
            Announcement.sample(id: "fresh", expiresAt: "2099-01-01T00:00:00Z"),
        ]
        let now = Date(timeIntervalSince1970: 1_781_136_000)
        let next = AnnouncementRules.next(list, isShown: { $0 == "shown" }, now: now)
        #expect(next?.id == "fresh")
        #expect(AnnouncementRules.next([list[0]], isShown: { _ in false }, now: now) == nil)
    }

    @Test func eachAnnouncementIsShownOnce() {
        let suite = "ann-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let telemetry = Telemetry(
            defaults: defaults, http: ScriptedHTTP([:]), baseURL: AccountClient.defaultBaseURL,
            sessionToken: { nil })
        let list = [Announcement.sample(id: "once", expiresAt: "2099-01-01T00:00:00Z")]
        #expect(AnnouncementRules.next(list, isShown: telemetry.isShown, now: Date()) != nil)
        telemetry.markShown("once")
        #expect(AnnouncementRules.next(list, isShown: telemetry.isShown, now: Date()) == nil)
    }
}

@Suite struct CrashReportTests {
    /// Header line, then the body, as macOS writes an `.ips` file. The paths in it are the person's own.
    private let ips = """
        {"app_name":"Bandito","timestamp":"2026-10-11 10:00:00.00 +1000","app_version":"0.1.10","bug_type":"309"}
        {"app_name":"Bandito","app_version":"0.1.10","bundleID":"dev.bandito.mac",
         "exception":{"codes":"0x1, 0x0","type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x10"},
         "usedImages":[
           {"source":"P","arch":"arm64","base":4294967296,"path":"/Users/alice/Applications/Bandito.app/Contents/MacOS/Bandito","name":"Bandito"},
           {"source":"S","arch":"arm64","base":1,"path":"/usr/lib/system/libsystem_kernel.dylib","name":"libsystem_kernel.dylib"}],
         "threads":[
           {"triggered":false,"frames":[{"imageOffset":5,"imageIndex":1,"symbol":"mach_msg"}]},
           {"triggered":true,"frames":[
             {"imageOffset":100,"imageIndex":0,"symbol":"StoreModel.save()","symbolLocation":12},
             {"imageOffset":200,"imageIndex":1,"symbol":"pthread_kill"},
             {"imageOffset":300,"imageIndex":1}]}]}
        """

    @Test func summaryHasKindAndTriggeredThreadFrames() throws {
        let summary = try #require(CrashReportParser.summary(from: Data(ips.utf8)))
        #expect(summary.kind == "EXC_BAD_ACCESS")
        #expect(
            summary.frames == [
                "Bandito`StoreModel.save()",
                "libsystem_kernel.dylib`pthread_kill",
                "libsystem_kernel.dylib`+300",
            ])
    }

    @Test func summaryNeverContainsAPath() throws {
        let summary = try #require(CrashReportParser.summary(from: Data(ips.utf8)))
        let text = summary.kind + summary.frames.joined()
        #expect(!text.contains("/"))
        #expect(!text.contains("alice"))
    }

    @Test func homeFolderPathsAreRemovedFromFrames() {
        let text = #"""
            {"x":1}
            {"exception":{"type":"EXC_CRASH /Users/alice/bad"},"usedImages":[{"name":"Bandito"}],
             "threads":[{"triggered":true,"frames":[
               {"imageIndex":0,"symbol":"load(/Users/alice/Projects/secret.swift:12)"}]}]}
            """#
        let summary = CrashReportParser.summary(from: Data(text.utf8))
        #expect(summary?.frames == ["Bandito`load(<path>"], "\(String(describing: summary))")
        #expect(summary?.kind == "EXC_CRASH <path>")
        let joined = summary?.frames.joined() ?? ""
        #expect(joined.contains("alice") == false, "frames: \(joined)")
    }

    @Test func framesAreCappedAndTrimmed() throws {
        let long = String(repeating: "x", count: 300)
        let frame = #"{"imageOffset":1,"imageIndex":0,"symbol":"\#(long)"}"#
        let frames = Array(repeating: frame, count: 80).joined(separator: ",")
        let body = #"{"exception":{"type":"EXC_CRASH"},"usedImages":[{"name":"Bandito"}],"threads":[{"triggered":true,"frames":[\#(frames)]}]}"#
        let text = "{\"header\":1}\n" + body
        let summary = try #require(CrashReportParser.summary(from: Data(text.utf8)))
        #expect(summary.frames.count == 64)
        #expect(summary.frames.allSatisfy { $0.count <= 200 })
    }

    @Test func brokenFileGivesNoSummary() {
        #expect(CrashReportParser.summary(from: Data("not a crash".utf8)) == nil)
    }

    @Test func scannerTakesOnlyBanditoReportsNewerThanTheLastSeen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-scan-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        for (name, date) in [("Bandito-old.ips", old), ("Bandito-new.ips", new), ("Other-new.ips", new), ("Bandito-new.txt", new)] {
            let url = folder.appendingPathComponent(name)
            try Data(ips.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        let reports = CrashReportScanner.reports(in: folder, modifiedAfter: Date(timeIntervalSince1970: 1_500_000))

        #expect(reports.map(\.url.lastPathComponent) == ["Bandito-new.ips"])
        #expect(reports.first?.modified == new)
    }
}

extension Announcement {
    static func sample(id: String, expiresAt: String) -> Announcement {
        let json = #"{"id":"\#(id)","title":"T","body":"B","level":"banner","expires_at":"\#(expiresAt)"}"#
        return try! TelemetryWire.decoder.decode(Announcement.self, from: Data(json.utf8))
    }
}
