@testable import BanditoKit
import BanditoL10n
import Testing
@testable import BanditoUI

struct SetupBadgeTests {
    private func runtime(_ kind: RuntimeKind, installed: Bool, loggedIn: Bool?) -> RuntimeStatus {
        RuntimeStatus(kind: kind, installed: installed, version: nil, loggedIn: loggedIn, detail: nil)
    }

    @Test func notInstalledIsDanger() {
        let badge = SetupBadge.runtime(runtime(.claude, installed: false, loggedIn: nil))
        #expect(badge.text == L10n.Server.Features.notInstalled)
        #expect(badge.tone == .danger)
        #expect(badge.help == nil)
    }

    @Test func notLoggedInIsWarningWithLoginCommand() {
        let codex = SetupBadge.runtime(runtime(.codex, installed: true, loggedIn: false))
        #expect(codex.text == L10n.Connect.needsLogin)
        #expect(codex.tone == .warning)
        #expect(codex.help == L10n.Server.Features.loginHelp(command: "codex login"))

        let grok = SetupBadge.runtime(runtime(.grok, installed: true, loggedIn: false))
        #expect(grok.help == L10n.Server.Features.loginHelp(command: "grok login"))
    }

    @Test func loggedInIsReady() {
        let badge = SetupBadge.runtime(runtime(.claude, installed: true, loggedIn: true))
        #expect(badge.text == L10n.Setup.ready)
        #expect(badge.tone == .ok)
    }

    @Test func installedWithoutLoginInfoIsInstalled() {
        let badge = SetupBadge.runtime(runtime(.claude, installed: true, loggedIn: nil))
        #expect(badge.text == L10n.Server.Features.installed)
        #expect(badge.tone == .neutral)
        #expect(badge.help == nil)
    }

    @Test func runtimeReportWinsOverSetupStatus() {
        let line = SetupLine(id: "codex", title: "Codex", state: .ready, hint: nil)
        let notLoggedIn = [runtime(.codex, installed: true, loggedIn: false)]
        #expect(SetupBadge.make(for: line, runtimes: notLoggedIn).tone == .warning)
    }

    @Test func setupStatusIsUsedWithoutRuntimeReport() {
        let ready = SetupLine(id: "claude", title: "Claude Code", state: .ready, hint: nil)
        #expect(SetupBadge.make(for: ready, runtimes: []) == SetupBadge(text: L10n.Setup.ready, tone: .ok, help: nil))

        let missing = SetupLine(id: "grok", title: "Grok", state: .missing, hint: nil)
        #expect(SetupBadge.make(for: missing, runtimes: []).tone == .neutral)
    }

    @Test func featureLinesIgnoreRuntimeReport() {
        let line = SetupLine(id: "browser", title: "Browser", state: .ready, hint: nil)
        let report = [runtime(.claude, installed: false, loggedIn: nil)]
        #expect(SetupBadge.make(for: line, runtimes: report).tone == .ok)
    }
}
