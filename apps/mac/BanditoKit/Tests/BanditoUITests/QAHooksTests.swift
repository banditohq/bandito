#if DEBUG && os(macOS)
import Testing

@testable import BanditoUI

@Suite struct QAHooksTests {
    @Test func modeAndSheetCommandsNameTheirTarget() {
        #expect(QACommand.parse("mode files") == .mode(.files))
        #expect(QACommand.parse("mode server") == .mode(.server))
        #expect(QACommand.parse("mode bogus") == nil)
        #expect(QACommand.parse("sheet addServer") == .sheet(.addServer))
        #expect(QACommand.parse("sheet newAgent") == .sheet(.newAgent))
        #expect(QACommand.parse("sheet account") == .sheet(.account))
        #expect(QACommand.parse("sheet changes") == nil)
        #expect(QACommand.parse("dismiss") == .dismiss)
        #expect(QACommand.parse("dismiss now") == nil)
    }

    @Test func windowCommandTakesWidthByHeight() {
        #expect(QACommand.parse("window 900x600") == .window(QASize(width: 900, height: 600)))
        #expect(QACommand.parse("window 2560x1440") == .window(QASize(width: 2560, height: 1440)))
        #expect(QACommand.parse("window 900") == nil)
        #expect(QACommand.parse("window 0x600") == nil)
        #expect(QACommand.parse("window -1x600") == nil)
        #expect(QACommand.parse("window axb") == nil)
        #expect(QACommand.parse("window") == nil)
    }

    @Test func filesCommandKeepsSpacesInThePath() {
        #expect(QACommand.parse("files /Users/me/My Project") == .files(path: "/Users/me/My Project"))
        #expect(QACommand.parse("files") == nil)
    }

    @Test func tabCommandNamesAServerSection() {
        #expect(QACommand.parse("tab journal") == .tab(.journal))
        #expect(QACommand.parse("tab overview") == .tab(.overview))
        #expect(QACommand.parse("tab nope") == nil)
    }

    @Test func settingsAndOnboardingTakeNoArgument() {
        #expect(QACommand.parse("settings") == .settings)
        #expect(QACommand.parse("onboarding") == .onboarding)
        #expect(QACommand.parse("onboarding again") == nil)
    }

    @Test func blankLinesAndUnknownWordsAreNotCommands() {
        #expect(QACommand.parse("") == nil)
        #expect(QACommand.parse("   ") == nil)
        #expect(QACommand.parse("reboot") == nil)
        #expect(QACommand.parse("  mode team  ") == .mode(.team))
    }

    @Test func aWindowSizeNeedsTwoPositiveSides() {
        #expect(QASize.parse("1200x800") == QASize(width: 1200, height: 800))
        #expect(QASize.parse("1200") == nil)
        #expect(QASize.parse("1200x800x3") == nil)
        #expect(QASize.parse("1200x") == nil)
    }
}
#endif
