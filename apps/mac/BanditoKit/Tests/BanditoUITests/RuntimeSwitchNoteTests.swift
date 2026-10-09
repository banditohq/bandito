import Foundation
import Testing

@testable import BanditoUI

@Suite struct RuntimeSwitchNoteTests {
    static let vladivostok = TimeZone(identifier: "Asia/Vladivostok")!

    /// 18:20 in Vladivostok (UTC+10) on 9 Oct 2026.
    static var resetAt: Int64 {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 8, minute: 20))!
        return Int64(date.timeIntervalSince1970)
    }

    @Test func switchToFallbackNamesTheRuntimeAndTheReset() {
        let text = RuntimeSwitchNote.text(
            from: "claude", to: "codex", until: Self.resetAt, primary: "claude", timeZone: Self.vladivostok)
        #expect(text.contains("Claude"))
        #expect(text.contains("Codex"))
        #expect(text.contains("18:20"))
    }

    @Test func switchWithoutResetTimeHasNoClock() {
        let text = RuntimeSwitchNote.text(
            from: "claude", to: "grok", until: nil, primary: "claude", timeZone: Self.vladivostok)
        #expect(text.contains("Grok"))
        #expect(!text.contains(":"))
    }

    @Test func switchingBackToThePrimaryIsAReturn() {
        let text = RuntimeSwitchNote.text(
            from: "codex", to: "claude", until: nil, primary: "claude", timeZone: Self.vladivostok)
        #expect(text.contains("Claude"))
        #expect(!text.contains("Codex"))
    }

    @Test func unknownRuntimeIsShownAsItIs() {
        #expect(RuntimeSwitchNote.runtimeName("gemini") == "gemini")
        #expect(RuntimeSwitchNote.runtimeName("codex") == "Codex")
    }
}
