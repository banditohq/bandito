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
        #expect(ServerFeaturesCard.symbol(for: "claude") == "cpu")
        #expect(ServerFeaturesCard.symbol(for: "git") == "shippingbox")
    }

    @Test func catalogLogosLoadFromTheBundle() {
        #expect(ServiceLogo.image(for: "github") != nil)
        #expect(ServiceLogo.image(for: "brave-search") != nil)
        #expect(ServiceLogo.image(for: "composio") == nil)
    }
}
