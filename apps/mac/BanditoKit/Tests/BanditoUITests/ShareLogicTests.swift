import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The rules of the share screens: links, the draft's limits, the buttons' states, the capabilities a shared bot
/// starts with, the preview cut, the texts of the failures, and the sources kept per share.
@Suite struct ShareLogicTests {
    private static let id = "k3HqT9vZ2Lm8pXcR4wBn7e"

    // MARK: links

    @Test func aPageLinkGivesItsID() {
        #expect(ShareLogic.shareID(fromLink: "https://bandito.dev/s/\(Self.id)") == Self.id)
        #expect(ShareLogic.shareID(fromLink: "  https://bandito.dev/s/\(Self.id)\n") == Self.id)
    }

    @Test func otherLinksGiveNothing() {
        #expect(ShareLogic.shareID(fromLink: "http://bandito.dev/s/\(Self.id)") == nil)
        #expect(ShareLogic.shareID(fromLink: "https://evil.example/s/\(Self.id)") == nil)
        #expect(ShareLogic.shareID(fromLink: "https://bandito.dev:8443/s/\(Self.id)") == nil)
        #expect(ShareLogic.shareID(fromLink: "https://bandito.dev/s/\(Self.id)?x=1") == nil)
        #expect(ShareLogic.shareID(fromLink: "https://bandito.dev/s/\(Self.id)/extra") == nil)
        #expect(ShareLogic.shareID(fromLink: "https://bandito.dev/s/short") == nil)
        #expect(ShareLogic.shareID(fromLink: "https://bandito.dev/x/\(Self.id)") == nil)
        #expect(ShareLogic.shareID(fromLink: "https://bandito.dev/s/\(Self.id)extra0") == nil)
        #expect(ShareLogic.shareID(fromLink: "to install it search for something") == nil)
    }

    @Test func anInstallURLGivesItsID() throws {
        let url = try #require(URL(string: "bandito://install?share=\(Self.id)"))
        #expect(ShareLogic.installID(fromURL: url) == Self.id)
    }

    @Test func aBadInstallURLIsIgnored() throws {
        let cases = [
            "bandito://install?share=short",
            "bandito://install?share=\(Self.id)&share=\(Self.id)",
            "bandito://install",
            "bandito://oauth/callback?share=\(Self.id)",
            "https://install?share=\(Self.id)",
            "bandito://install?share=../../etc",
        ]
        for text in cases {
            let url = try #require(URL(string: text))
            #expect(ShareLogic.installID(fromURL: url) == nil, "\(text)")
        }
    }

    @Test func thePageURLIsTheHTTPSLinkOfTheID() {
        #expect(ShareLogic.pageURL(id: Self.id) == "https://bandito.dev/s/\(Self.id)")
    }

    // MARK: draft

    @Test func aTitleIsOneToEightyCharactersOnceTrimmed() {
        #expect(!ShareLogic.isTitleValid(""))
        #expect(!ShareLogic.isTitleValid("   "))
        #expect(ShareLogic.isTitleValid("a"))
        #expect(ShareLogic.isTitleValid(String(repeating: "x", count: 80)))
        #expect(!ShareLogic.isTitleValid(String(repeating: "x", count: 81)))
    }

    @Test func aSummaryIsAtMostTwoHundredEightyCharacters() {
        #expect(ShareLogic.isSummaryValid(""))
        #expect(ShareLogic.isSummaryValid(String(repeating: "y", count: 280)))
        #expect(!ShareLogic.isSummaryValid(String(repeating: "y", count: 281)))
    }

    @Test func publishNeedsSignInAPayloadAValidDraftAndNoRequestRunning() {
        let good = { (signedIn: Bool, payload: Bool, inFlight: Bool) in
            ShareLogic.canPublish(
                title: "Notes", summary: "", hasPayload: payload, signedIn: signedIn, inFlight: inFlight)
        }
        #expect(good(true, true, false))
        #expect(!good(false, true, false))
        #expect(!good(true, false, false))
        #expect(!good(true, true, true))
        #expect(!ShareLogic.canPublish(
            title: "  ", summary: "", hasPayload: true, signedIn: true, inFlight: false))
    }

    @Test func installNeedsAServerAnItemAndTheTickForScripts() {
        #expect(ShareLogic.canInstall(hasServer: true, hasItem: true, executables: [], acknowledged: false, inFlight: false))
        #expect(!ShareLogic.canInstall(hasServer: false, hasItem: true, executables: [], acknowledged: false, inFlight: false))
        #expect(!ShareLogic.canInstall(hasServer: true, hasItem: false, executables: [], acknowledged: false, inFlight: false))
        #expect(!ShareLogic.canInstall(hasServer: true, hasItem: true, executables: [], acknowledged: false, inFlight: true))
        #expect(!ShareLogic.canInstall(
            hasServer: true, hasItem: true, executables: ["scripts/run.sh"], acknowledged: false, inFlight: false))
        #expect(ShareLogic.canInstall(
            hasServer: true, hasItem: true, executables: ["scripts/run.sh"], acknowledged: true, inFlight: false))
    }

    // MARK: capabilities

    @Test func riskyCapabilitiesStartOff() {
        let offered = ShareLogic.offeredCapabilities(["team", "files", "terminal", "screen", "browser"])
        let on = ShareLogic.defaultCapabilities(offered)
        #expect(on == [.files, .browser])
    }

    @Test func offeredCapabilitiesKeepOnlyKnownNamesInChipOrder() {
        let offered = ShareLogic.offeredCapabilities(["screen", "made-up", "files", "files"])
        #expect(offered == [.files, .screen])
    }

    @Test func theSentListIsAnOrderedSubsetOfThePayload() {
        let offered = ShareLogic.offeredCapabilities(["terminal", "files", "browser"])
        let chosen: Set<AgentCapability> = [.browser, .terminal]
        #expect(ShareLogic.chosenCapabilities(chosen, offered: offered) == ["terminal", "browser"])
        #expect(ShareLogic.chosenCapabilities([], offered: offered).isEmpty)
    }

    // MARK: payload

    @Test func aBotPayloadShowsItsParts() throws {
        let payload: JSONValue = .object([
            "schema": .number(1),
            "name": .string("Release notes"),
            "role": .string("Writes notes"),
            "system_prompt": .string("Be brief."),
            "capabilities": .array([.string("files"), .string("terminal")]),
            "services": .array([.string("github")]),
            "schedules": .array([.object(["cron": .string("0 9 * * 1"), "prompt": .string("Go")])]),
            "starter": .string("Hi"),
        ])
        let info = try #require(SharedPayloadInfo(kind: .bot, payload: payload))
        #expect(info.name == "Release notes")
        #expect(info.role == "Writes notes")
        #expect(info.systemPrompt == "Be brief.")
        #expect(info.capabilities == ["files", "terminal"])
        #expect(info.serviceCount == 1)
        #expect(info.scheduleCount == 1)
        #expect(info.starter == "Hi")
    }

    @Test func aSkillPayloadListsItsFilesAndScripts() throws {
        let payload: JSONValue = .object([
            "schema": .number(1),
            "name": .string("pdf"),
            "description": .string("PDFs"),
            "license": .string("MIT"),
            "files": .object(["scripts/run.sh": .string("x"), "SKILL.md": .string("y")]),
            "executable": .array([.string("scripts/run.sh")]),
        ])
        let info = try #require(SharedPayloadInfo(kind: .skill, payload: payload))
        #expect(info.files == ["SKILL.md", "scripts/run.sh"])
        #expect(info.executables == ["scripts/run.sh"])
        #expect(info.license == "MIT")
    }

    @Test func aPayloadWithoutANameIsNotShown() {
        #expect(SharedPayloadInfo(kind: .bot, payload: .object(["role": .string("x")])) == nil)
    }

    @Test func thePayloadTextKeepsItsKeys() {
        let text = ShareLogic.payloadText(.object(["system_prompt": .string("p"), "my_file.py": .string("q")]))
        #expect(text.contains("\"system_prompt\""))
        #expect(text.contains("\"my_file.py\""))
    }

    @Test func aLongPreviewIsCutToTwelveLines() {
        let short = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let shortPreview = ShareLogic.preview(of: short)
        #expect(!shortPreview.isCollapsed)
        #expect(shortPreview.shown == short)

        let long = (1...13).map { "line \($0)" }.joined(separator: "\n")
        let longPreview = ShareLogic.preview(of: long)
        #expect(longPreview.isCollapsed)
        #expect(longPreview.shown.split(separator: "\n").count == ShareLogic.previewLineLimit)
        #expect(longPreview.shown.hasSuffix("line 12"))
    }

    // MARK: texts

    @Test func aSecretRefusalNamesTheField() {
        #expect(ShareLogic.publishMessage(for: .looksLikeSecret(field: "summary")).contains("summary"))
    }

    @Test func theFailuresHaveTheirOwnTexts() {
        let texts = [
            ShareLogic.publishMessage(for: .rate),
            ShareLogic.publishMessage(for: .tooMany),
            ShareLogic.publishMessage(for: .hidden),
            ShareLogic.publishMessage(for: .notFound),
            ShareLogic.publishMessage(for: .unauthorized),
        ]
        #expect(Set(texts).count == texts.count)
        #expect(ShareLogic.fetchMessage(for: .notFound) == ShareLogic.publishMessage(for: .notFound))
    }

    @Test func aDaemonRefusalHasItsOwnTextAndAnExistingSkillIsNamed() {
        let reasons = [
            "catalog_skill", "not_yours", "license_required", "no_skill", "unsafe_path", "bad_path", "not_utf8",
            "too_large", "exists_not_ours", "io",
        ]
        let texts = reasons.map { ShareLogic.installMessage(for: .reason($0)) }
        #expect(Set(texts).count == reasons.count)
        #expect(ShareLogic.installMessage(for: .invalid(field: "system_prompt")).contains("system_prompt"))
    }

    // MARK: sources

    @Test func theSourceOfAShareIsKeptPerShareOnThisMac() throws {
        let suite = "share-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let source = ShareSource(kind: .bot, serverID: "srv-1", agentID: "agent-1")
        ShareSourceStore.remember(source, for: Self.id, defaults: defaults)
        #expect(ShareSourceStore.load(defaults: defaults)[Self.id] == source)

        ShareSourceStore.forget(Self.id, defaults: defaults)
        #expect(ShareSourceStore.load(defaults: defaults).isEmpty)
    }

    @Test func onlyAShareWithAKnownSourceCanBeUpdated() {
        let item = ShareSummary(
            id: Self.id, kind: .skill, visibility: .link, title: "pdf", summary: "", lang: nil, version: 1,
            installs: 0, hidden: false, createdAt: 0, updatedAt: 0)
        #expect(!ShareLogic.canUpdate(item, sources: [:]))
        #expect(ShareLogic.canUpdate(item, sources: [Self.id: ShareSource(kind: .skill, serverID: "s", skillName: "pdf")]))
    }
}
