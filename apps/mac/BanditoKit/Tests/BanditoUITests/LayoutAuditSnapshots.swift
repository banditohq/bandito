import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import Testing

@testable import BanditoUI

/// The layout audit: every sheet, dialog and Settings section at its narrowest width, in the two languages with the
/// longest words (German) and the widest letters (Russian). See `apps/mac/CLAUDE.md`, Rules.
///
/// A new sheet, dialog or Settings section gets an entry in `LayoutAuditSnapshots.cases`. Run it with
/// `LAYOUT_AUDIT_DIR=$(mktemp -d) swift test --filter LayoutAudit` and look at the German pictures: nothing may run past
/// its box, hide behind another element, or be cut without an ellipsis.
@MainActor
@Suite(.serialized) struct LayoutAuditSnapshots {
    static let languages = ["de", "ru"]

    /// Right column of Settings at the smallest window: 760 pt window minus the 240 pt navigation.
    static let settingsColumn: CGFloat = 520

    static var cases: [AuditCase] { settings + sheets + dataSheets + serverScreens + marketScreens + onboardingScreens + flowSheets }

    static let settings: [AuditCase] = [
        AuditCase(name: "settings-general", width: settingsColumn, scrolls: true) { _ in AnyView(GeneralSection()) },
        AuditCase(name: "settings-account", width: settingsColumn, scrolls: true) { _ in AnyView(AccountSection()) },
        AuditCase(name: "settings-servers", width: settingsColumn, scrolls: true) { _ in AnyView(ServersSection()) },
        AuditCase(name: "settings-approvals", width: settingsColumn, scrolls: true) { _ in AnyView(ApprovalsSection()) },
        AuditCase(name: "settings-usage", width: settingsColumn, scrolls: true) { _ in AnyView(UsageSection()) },
        AuditCase(name: "settings-terminal-files", width: settingsColumn, scrolls: true) { _ in AnyView(TerminalFilesSection()) },
        AuditCase(name: "settings-browser-screen", width: settingsColumn, scrolls: true) { _ in AnyView(BrowserScreenSection()) },
        AuditCase(name: "settings-keys-gestures", width: settingsColumn, scrolls: true) { _ in AnyView(KeysAndGesturesSection()) },
        AuditCase(name: "settings-notifications", width: settingsColumn, scrolls: true) { _ in AnyView(NotificationsSection()) },
        AuditCase(name: "settings-appearance", width: settingsColumn, scrolls: true) { _ in AnyView(AppearanceSection()) },
        AuditCase(name: "settings-updates", width: settingsColumn, scrolls: true) { _ in AnyView(UpdatesSection()) },
        AuditCase(name: "settings-privacy", width: settingsColumn, scrolls: true) { _ in AnyView(PrivacySection()) },
        AuditCase(name: "settings-telegram-new", width: settingsColumn, scrolls: true) { _ in
            AnyView(
                TelegramPage(
                    status: TelegramStatus(configured: false, bot: nil, running: false, lastError: nil, chats: []),
                    actions: .preview))
        },
        AuditCase(name: "settings-telegram-chats", width: settingsColumn, scrolls: true) { _ in
            AnyView(
                TelegramPage(
                    status: TelegramStatus(
                        configured: true, bot: TelegramBot(username: "bandito_dev_bot", name: "Bandito"),
                        running: false, lastError: "conflict",
                        chats: [
                            TelegramChat(
                                chatId: 1001, title: "Anna", language: "ru", linkedAt: 1_786_000_000_000,
                                approvals: true, answers: .telegram),
                            TelegramChat(
                                chatId: 1002, title: "Max", language: "en", linkedAt: 1_786_100_000_000,
                                approvals: false, answers: .none),
                        ]),
                    actions: .preview))
        },
    ]

    static let sheets: [AuditCase] = [
        AuditCase(name: "sheet-file-name", width: 380, selfSized: true) { _ in
            AnyView(FileNameSheet(sheet: .folder, existing: [], onSubmit: { _ in }))
        },
        AuditCase(name: "sheet-telemetry-notice", width: 480, selfSized: true) { env in
            AnyView(TelemetryNoticeSheet(telemetry: env.telemetry))
        },
        AuditCase(name: "sheet-telemetry-delete", width: 440, selfSized: true) { _ in
            AnyView(
                TelemetryConfirmSheet(
                    title: L10n.Settings.Privacy.deleteTitle, message: L10n.Settings.Privacy.deleteBody,
                    confirmTitle: L10n.Common.delete, confirmIsDanger: true, onConfirm: {}, onCancel: {}))
        },
        AuditCase(name: "sheet-telemetry-crash", width: 440, selfSized: true) { _ in
            AnyView(
                TelemetryConfirmSheet(
                    title: L10n.Telemetry.Crash.title, message: L10n.Telemetry.Crash.body,
                    confirmTitle: L10n.Telemetry.Crash.send, confirmIsDanger: false,
                    cancelTitle: L10n.Telemetry.Notice.decline, onConfirm: {}, onCancel: {}))
        },
        AuditCase(name: "sheet-snippet", width: 440, selfSized: true) { _ in AnyView(SnippetEditor(onSave: { _ in })) },
        AuditCase(name: "sheet-telegram-link", width: 420, selfSized: true) { _ in
            AnyView(TelegramLinkSheet(isPresented: .constant(true), request: { throw URLError(.badURL) }))
        },
    ]

    // MARK: sheets with data

    static func decode<T: Decodable>(_ type: T.Type, _ raw: String) -> T {
        // The test fails at once, with the text, if a sample no longer decodes.
        do { return try RPCClient.decoder.decode(T.self, from: Data(raw.utf8)) } catch { fatalError("sample: \(error)\n\(raw)") }
    }

    static let longPrompt =
        "Collect the open pull requests of the team repositories, check which of them wait for a review for more than two days and write the list into the team channel with the names of the authors."

    static let schedule = decode(
        Schedule.self,
        ##"{"id":"s1","agent_id":"a1","cron":"0 9 * * 1-5","tz":"Europe/Berlin","prompt":"Collect the open pull requests","enabled":true,"created_at":1,"title":"Weekday review reminder","human_en":"At 09:00 on weekdays","human_ru":"В 09:00 по будням"}"##)

    /// An agent that moves in the sheet: a long name on purpose (the title allows two lines).
    static let movingAgent = Agent(
        id: "a1", name: "Forge with a long name for the layout check", runtime: .claude, cwd: "/work/forge")

    /// The same agent on the server it moved from: the strip shows where it went.
    static let movedAgent = Agent(
        id: "a1", name: "Forge with a long name for the layout check", runtime: .claude, cwd: "/work/forge",
        paused: true, migratedTo: "Production server in the Frankfurt datacenter", migratedAt: 1_786_000_000_000)

    static let linear = IntegrationCatalogEntry(
        id: "linear", name: "Linear", descriptionEn: "Issues and projects", descriptionRu: "Задачи и проекты",
        kind: .http, url: "https://mcp.linear.app/mcp",
        headersKeys: [
            IntegrationHeaderKey(
                key: "Authorization", labelEn: "Personal API key", labelRu: "Личный ключ API", secret: true,
                valueTemplate: "Bearer {secret}")
        ], docsUrl: "https://linear.app/docs", icon: "linear", accent: "#5E6AD2",
        needsEn: "A personal API key from the Linear settings, section Security.",
        needsRu: "Личный ключ API из настроек Linear, раздел Безопасность.")

    static let filesystem = IntegrationCatalogEntry(
        id: "filesystem", name: "Filesystem", descriptionEn: "Read and write files", descriptionRu: "Чтение и запись файлов",
        kind: .stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/maria/projects/very-long-folder-name"],
        envKeys: [
            IntegrationHeaderKey(
                key: "ALLOWED_DIRECTORIES", labelEn: "Allowed folders", labelRu: "Разрешённые папки", secret: false,
                valueTemplate: "{secret}")
        ], docsUrl: "https://example.com", icon: "folder", accent: "#3F7F5F")

    static let dataSheets: [AuditCase] = [
        AuditCase(name: "sheet-schedule-new", width: 480, selfSized: true) { env in
            AnyView(ScheduleEditor(server: env.server, agentID: "a1", existing: nil))
        },
        AuditCase(name: "sheet-schedule-edit", width: 480, selfSized: true) { env in
            AnyView(ScheduleEditor(server: env.server, agentID: "a1", existing: schedule))
        },
        AuditCase(name: "sheet-share-bot", width: 480, selfSized: true, signedIn: true) { _ in
            AnyView(ShareSheet(subject: .bot(agentID: "agent-1"), server: nil, model: ShareSamples.publishDraft))
        },
        AuditCase(name: "sheet-share-published", width: 480, selfSized: true, signedIn: true) { _ in
            AnyView(ShareSheet(subject: .bot(agentID: "agent-1"), server: nil, model: ShareSamples.published))
        },
        AuditCase(name: "sheet-install-bot", width: 460, selfSized: true, signedIn: true) { _ in
            AnyView(
                InstallSharedSheet(
                    shareID: ShareSamples.shareID, server: nil,
                    model: InstallSharedModel(load: .loaded(ShareSamples.bot))))
        },
        AuditCase(name: "sheet-install-skill", width: 460, selfSized: true, signedIn: true) { _ in
            AnyView(
                InstallSharedSheet(
                    shareID: ShareSamples.shareID, server: nil,
                    model: InstallSharedModel(load: .loaded(ShareSamples.skill))))
        },
        AuditCase(name: "sheet-install-failed", width: 460, selfSized: true) { _ in
            AnyView(
                InstallSharedSheet(
                    shareID: ShareSamples.shareID, server: nil,
                    model: InstallSharedModel(load: .failed(ShareLogic.fetchMessage(for: .notFound)))))
        },
        AuditCase(name: "sheet-my-shares", width: 540, selfSized: true, signedIn: true) { env in
            AnyView(MySharesView(servers: [], model: MySharesModel(phase: .loaded, items: ShareSamples.mine)))
        },
        AuditCase(name: "sheet-my-shares-empty", width: 540, selfSized: true, signedIn: true) { _ in
            AnyView(MySharesView(servers: [], model: MySharesModel(phase: .loaded, items: [])))
        },
        AuditCase(name: "sheet-workspace-create", width: 480, selfSized: true) { env in
            AnyView(WorkspaceCreateSheet(model: WorkspacesModel(server: env.server), onDone: {}))
        },
        AuditCase(name: "sheet-pair", width: 420, selfSized: true) { env in AnyView(PairSheet(server: env.server)) },
        AuditCase(name: "sheet-secret-new", width: 460, selfSized: true) { env in
            AnyView(SecretEditor(draft: .new(), server: env.server, onSaved: {}))
        },
        AuditCase(name: "sheet-conflict-diff", width: 640, height: 520, selfSized: true) { _ in
            AnyView(
                ConflictDiffSheet(
                    serverText: "line one\nline two changed on the server\nline three",
                    mineText: "line one\nline two changed on this Mac\nline three\nline four"))
        },
        AuditCase(name: "sheet-integration-token", width: 540, selfSized: true) { env in
            AnyView(
                IntegrationEditor(
                    server: env.server, target: .catalog(linear), existingNames: [], onChecked: { _, _ in }, onSaved: {}))
        },
        AuditCase(name: "sheet-integration-command", width: 540, selfSized: true) { env in
            AnyView(
                IntegrationEditor(
                    server: env.server, target: .catalog(filesystem), existingNames: [], onChecked: { _, _ in },
                    onSaved: {}))
        },
        AuditCase(name: "sheet-integration-edit", width: 540, selfSized: true) { env in
            AnyView(
                IntegrationEditor(
                    server: env.server,
                    target: .edit(
                        Integration(
                            id: "i1", name: "linear", kind: .http, url: "https://mcp.linear.app/mcp",
                            headers: ["Authorization": "Bearer ${secret:linear-key}"])),
                    existingNames: ["linear"], onChecked: { _, _ in }, onSaved: {}))
        },
        AuditCase(name: "sheet-integration-custom", width: 520, selfSized: true) { env in
            AnyView(CustomIntegrationSheet(server: env.server, existingNames: [], onChecked: { _, _ in }, onSaved: {}))
        },
        AuditCase(name: "sheet-move-agent", width: 520, selfSized: true) { env in
            AnyView(
                MoveAgentSheet(
                    source: env.server, agent: movingAgent, targets: Array(env.app.servers.dropFirst()),
                    preselectedTargetID: env.app.servers.dropFirst().first?.id))
        },
        AuditCase(name: "migrated-agent-strip", width: 560) { env in
            AnyView(MigratedAgentStrip(agent: movedAgent, source: env.server, movedTo: "Production server in the Frankfurt datacenter"))
        },
        AuditCase(name: "sheet-folder-picker", width: 540, height: 380, selfSized: true) { env in
            AnyView(FolderPicker(server: env.server, selection: .constant("/Users/maria/projects"), onChoose: {}))
        },
        AuditCase(name: "sheet-import", width: 720, height: 600, selfSized: true) { _ in AnyView(ImportSheet()) },
        AuditCase(name: "sheet-new-agent", width: 640, height: 540, selfSized: true) { _ in AnyView(NewAgentSheet()) },
        AuditCase(name: "sheet-add-server", width: 680, height: 460, selfSized: true) { _ in AnyView(AddServerSheet()) },
        AuditCase(name: "sheet-account-signed-out", width: ProfileSheetLayout.width, selfSized: true) { _ in
            AnyView(AccountSheet())
        },
        AuditCase(name: "sheet-account-signed-in", width: ProfileSheetLayout.width, selfSized: true, signedIn: true) { env in
            let me = ##"""
                {"user":{"id":"u1","email":"maria.wolfgang-schneider@example-company.com","name":"Maria Wolfgang-Schneider","github_login":"maria"},
                 "device":{"id":"d1","approved":true},
                 "devices":[
                  {"id":"d1","name":"MacBook Pro of Maria Wolfgang-Schneider","platform":"macOS","approved":true,"created_at":"2026-09-01T10:00:00Z","last_seen_at":"2026-10-10T10:00:00Z","current":true},
                  {"id":"d2","name":"iPhone","platform":"iOS","approved":true,"created_at":"2026-09-02T10:00:00Z","last_seen_at":"2026-10-09T10:00:00Z","current":false}]}
                """##
            let pending = ##"""
                [{"id":"p1","name":"Mac mini in the office of the company","platform":"macOS","public_key":"AAAA","created_at":"2026-10-10T10:00:00Z"}]
                """##
            env.hub.me = try? JSONDecoder().decode(Me.self, from: Data(me.utf8))
            env.hub.pending = (try? JSONDecoder().decode([PendingDevice].self, from: Data(pending.utf8))) ?? []
            return AnyView(AccountSheet())
        },
    ]

    /// Renders every case in German and Russian into `LAYOUT_AUDIT_DIR` (skipped when it is not set, so CI stays fast) and
    /// fails, naming the view, for each one whose content needs more width than its container has or draws outside it.
    /// Text that is cut inside a box, or hidden behind another element, is not found by numbers: look at the pictures.
    @Test(.enabled(if: LayoutAudit.outputDirectory != nil)) func gallery() throws {
        let directory = try #require(LayoutAudit.outputDirectory)
        defer { LayoutAudit.finish() }
        var findings: [AuditFinding] = []
        for language in Self.languages {
            LayoutAudit.use(language: language)
            for item in Self.cases {
                findings.append(LayoutAudit.audit(item, language: language, into: directory))
            }
        }
        print("AUDIT \(findings.count) pictures in \(directory.path)")
        for finding in findings where finding.isProblem {
            Issue.record("Layout: \(finding)")
        }
    }
}

/// The audit itself must not go blind: a view that is wider than its box has to be reported, a view that fits must not.
@MainActor
@Suite(.serialized) struct LayoutAuditDetectorTests {
    private func finding(_ view: some View, width: CGFloat) -> AuditFinding {
        LayoutAudit.audit(AuditCase(name: "probe", width: width) { _ in AnyView(view) }, language: "en", into: nil)
    }

    @Test func aRowThatCannotShrinkIsReported() {
        let wide = HStack(spacing: 8) {
            Text("A button that does not fit").fixedSize()
            Text("Another one that does not fit either").fixedSize()
        }
        let result = finding(wide, width: 200)
        #expect(result.isProblem)
        #expect(result.requiredWidth > 200)
        #expect(result.spilledPixels > 0)
    }

    @Test func aRowThatFitsIsNotReported() {
        let result = finding(Text("Short").padding(), width: 200)
        #expect(!result.isProblem)
    }

    @Test func textThatWrapsIsNotReported() {
        let result = finding(Text(String(repeating: "A long sentence that wraps. ", count: 8)).padding(), width: 200)
        #expect(!result.isProblem)
    }
}
