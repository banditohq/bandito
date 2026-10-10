import AppKit
import BanditoL10n
import Testing

@testable import BanditoUI

@Suite struct ServerOverviewTests {
    @Test func tileValueSplitsNumberFromUnit() {
        let gigabytes = OverviewTileText.split("5,1 ГБ")
        #expect(gigabytes.number == "5,1")
        #expect(gigabytes.unit == "ГБ")

        let rate = OverviewTileText.split("1,9 МБ/с")
        #expect(rate.number == "1,9")
        #expect(rate.unit == "МБ/с")

        let percent = OverviewTileText.split("38%")
        #expect(percent.number == "38")
        #expect(percent.unit == "%")
    }

    @Test func tileValueWithoutUnitStaysWhole() {
        let plain = OverviewTileText.split("12")
        #expect(plain.number == "12")
        #expect(plain.unit == nil)
    }

    @Test func uptimeReadsHoursBelowADayAndDaysFromADay() {
        #expect(ServerPassport.uptimeText(seconds: 0) == L10n.Server.Passport.uptimeLessHour)
        #expect(ServerPassport.uptimeText(seconds: 3599) == L10n.Server.Passport.uptimeLessHour)
        #expect(ServerPassport.uptimeText(seconds: 3600) == L10n.Server.Passport.uptimeHours(count: 1))
        #expect(ServerPassport.uptimeText(seconds: 86_399) == L10n.Server.Passport.uptimeHours(count: 23))
        #expect(ServerPassport.uptimeText(seconds: 86_400) == L10n.Inspector.uptime(count: 1))
    }

    @Test func negativeUptimeIsTreatedAsNone() {
        #expect(ServerPassport.uptimeText(seconds: -5) == L10n.Server.Passport.uptimeLessHour)
    }

    @Test func featureChipTonesKeepTheStatusColours() {
        #expect(ServerFeaturesCard.chipTone(.ok) == .ok)
        #expect(ServerFeaturesCard.chipTone(.warning) == .signal)
        #expect(ServerFeaturesCard.chipTone(.danger) == .neutral)
    }

    @Test func featureSymbolTellsRuntimesFromOtherParts() {
        #expect(ServerFeaturesCard.symbol(for: "claude") == "sparkle")
        #expect(ServerFeaturesCard.symbol(for: "browser") == "globe")
        #expect(ServerFeaturesCard.symbol(for: "git") == "puzzlepiece.extension")
    }

    @Test func catalogLogosLoadFromTheBundle() {
        #expect(ServiceLogo.image(for: "github") != nil)
        #expect(ServiceLogo.image(for: "linear") != nil)
        #expect(ServiceLogo.image(for: "notion") != nil)
        #expect(ServiceLogo.image(for: "sentry") != nil)
        #expect(ServiceLogo.image(for: "brave-search") != nil)
        for id in ["gitlab", "vercel", "netlify", "toolbox-postgres", "grafana", "posthog", "huggingface", "mongodb",
                   "railway", "render", "snyk", "prisma"] {
            #expect(ServiceLogo.image(for: id) != nil, "\(id)")
        }
        #expect(ServiceLogo.image(for: "neon") == nil)
        #expect(ServiceLogo.image(for: "composio") == nil)
    }

    @Test func logoIsReadOnceAndAMissIsRemembered() {
        final class Counter: @unchecked Sendable { var reads = 0 }
        let counter = Counter()
        let cache = ServiceLogoCache { id in
            counter.reads += 1
            return id == "github" ? NSImage(size: NSSize(width: 1, height: 1)) : nil
        }
        let first = cache.image(for: "github")
        let second = cache.image(for: "github")
        #expect(first != nil)
        #expect(first === second)
        #expect(counter.reads == 1)

        #expect(cache.image(for: "composio") == nil)
        #expect(cache.image(for: "composio") == nil)
        #expect(counter.reads == 2)
    }

    @Test func serviceLogoUsesTheSharedCache() {
        let first = ServiceLogo.image(for: "stripe")
        let second = ServiceLogo.image(for: "stripe")
        #expect(first != nil)
        #expect(first === second)
    }
}
