import BanditoDesign
@testable import BanditoKit
import SwiftUI
import Testing

@testable import BanditoL10n
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

    static var cases: [AuditCase] {
        settings + sheets + dataSheets + serverScreens + marketScreens + onboardingScreens + flowSheets + browserScreens
            + approvalViews + messageTimeRows
    }

    static let settings: [AuditCase] = [
        AuditCase(name: "settings-general", width: settingsColumn, scrolls: true) { _ in AnyView(GeneralSection()) },
        AuditCase(name: "settings-account", width: settingsColumn, scrolls: true) { _ in AnyView(AccountSection()) },
        AuditCase(name: "settings-servers", width: settingsColumn, scrolls: true) { _ in AnyView(ServersSection()) },
        AuditCase(name: "settings-server-detail", width: settingsColumn, scrolls: true) { env in
            env.serverInfo(features: ["server_settings", "backups", "host", "logs"])
            return AnyView(
                ServerSettingsPage(
                    server: env.server, onBack: {}, preview: serverSettingsPreview, previewStats: serverHostPreview))
        },
        AuditCase(name: "settings-server-detail-old", width: settingsColumn, scrolls: true) { env in
            env.serverInfo(version: "0.1.4", features: ["host"])
            return AnyView(ServerSettingsPage(server: env.server, onBack: {}, previewStats: serverHostPreview))
        },
        AuditCase(name: "settings-server-detail-ssh", width: settingsColumn, scrolls: true) { _ in
            AnyView(
                ServerSettingsPage(
                    server: sshServerForAudit(), onBack: {}, preview: serverSettingsPreview,
                    previewStats: serverHostPreview))
        },
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

    /// The settings page's values and host numbers without a server: long names and the largest choices on purpose.
    static let serverSettingsPreview = ServerSettingsSnapshot(
        settings: ServerSettingValues(
            screenIdleMinutes: 240, maxRunningAgents: 50, backupEveryHours: 168, backupKeep: 60, autoUpdate: .install,
            updateChannel: "stable", defaultApprovalMode: .always),
        defaults: ServerSettingValues(
            screenIdleMinutes: 30, maxRunningAgents: 0, backupEveryHours: 24, backupKeep: 14, autoUpdate: .notify,
            updateChannel: "stable", defaultApprovalMode: .risky))

    /// A server reached over ssh with a key file, that answers the features of the settings page (never connected).
    static func sshServerForAudit() -> ServerModel {
        let server = ServerModel(
            config: ServerConfig(
                name: "Build machine in the Frankfurt datacenter",
                endpoint: .ssh(
                    server: SSHServerAddress(
                        host: "build-frankfurt-01.example.internal", user: "deploy", port: 2222,
                        identityFile: "/Users/anna/.ssh/id_ed25519_build"),
                    remotePort: 7878)))
        server.info = decode(
            DaemonInfo.self,
            #"{"version":"0.1.11","hostname":"audit","os":"linux","arch":"x86_64","started_at":1,"last_seq":0,"features":["server_settings","backups","host","logs"]}"#)
        return server
    }

    static let serverHostPreview = decode(
        HostStats.self,
        #"{"os":"Ubuntu 24.04.2 LTS","kernel":"6.8.0-45-generic","arch":"x86_64","hostname":"audit","cpus":16,"cpu_percent":12.5,"load":[0.4,0.3,0.2],"mem_total":68719476736,"mem_used":17179869184,"swap_total":0,"swap_used":0,"disks":[{"mount":"/","total":1000000000000,"used":412000000000}],"net_rx_bps":0,"net_tx_bps":0,"net_supported":true,"uptime_s":1900000}"#)

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

    // MARK: browser page area

    /// The page area of Browser mode at its narrowest (a panel in the workbench is narrower than the window).
    static let browserStartRecent = [
        "https://www.marketplace.example.com/catalog/category/very-long-path/item-with-a-long-name?ref=start",
        "https://docs.example.org/guide/getting-started",
        "https://news.example.net/",
    ]

    static let browserStartAgentTabs = [
        BrowserTab(id: "A1", title: "Заказ №4417 — оплата", url: "https://shop.example.ru/order/4417", agent: true),
        BrowserTab(id: "A2", title: "", url: "https://api.example.com/v2/reports/monthly", agent: true),
    ]

    static let browserScreens: [AuditCase] = [
        AuditCase(name: "browser-no-tabs", width: 420, height: 300) { _ in
            AnyView(BrowserNoTabsView(onNewTab: {}))
        },
        AuditCase(name: "browser-start-page", width: 420, height: 520) { _ in
            AnyView(
                BrowserStartPageView(
                    recent: browserStartRecent, agentTabs: browserStartAgentTabs,
                    onOpenAddress: { _ in }, onSelectTab: { _ in }))
        },
        AuditCase(name: "browser-frame-timeout", width: 420, height: 260) { _ in
            AnyView(BrowserFrameTimedOutView(onRetry: {}))
        },
    ]

    // MARK: the time of a message in its row of actions

    /// The row under a message on hover, as `MessageContainer` draws it: the icons, and the time at the far end from the
    /// bubble's edge. The date is the longest form (an older year), so the row is checked at its widest.
    static let messageTimeRows: [AuditCase] = [
        AuditCase(name: "message-time-row-person", width: 360) { _ in AnyView(messageTimeRow(fromUser: true)) },
        AuditCase(name: "message-time-row-agent", width: 360) { _ in AnyView(messageTimeRow(fromUser: false)) },
    ]

    static func messageTimeRow(fromUser: Bool) -> some View {
        let sent = Calendar.current.date(
            from: DateComponents(year: 2025, month: 10, day: 11, hour: 22, minute: 14, second: 37)) ?? .distantPast
        return HStack(spacing: 2) {
            if fromUser {
                MessageTimeStamp(date: sent).equatable()
                auditRowIcon("doc.on.doc", label: L10n.Thread.copy)
                auditRowIcon("arrowshape.turn.up.left", label: L10n.Thread.reply)
                auditRowIcon("face.smiling", label: L10n.Message.react)
            } else {
                auditRowIcon("doc.on.doc", label: L10n.Thread.copy)
                auditRowIcon("face.smiling", label: L10n.Message.react)
                auditRowIcon("arrowshape.turn.up.left", label: L10n.Thread.reply)
                auditRowIcon("ellipsis", label: L10n.Message.more)
                MessageTimeStamp(date: sent).equatable()
            }
        }
        .frame(height: MessageActionsPlacement.rowHeight)
    }

    /// One icon of the row, drawn with the row's own button style.
    private static func auditRowIcon(_ symbol: String, label: String) -> some View {
        Button {
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(MessageActionStyle(label: label))
    }

    // MARK: approvals in the thread and the agent's details

    /// A request that waits for the person: the command, and the reason in the daemon's words.
    static let pendingApproval = ApprovalRow(
        approvalId: "ap1", tool: "bash", title: "Run a command", command: "git push origin release/0.1.11",
        diff: nil, reason: "risky: git push", state: .pending)

    /// A request to create an agent, with a summary that fills every row with long words.
    static let createApproval = ApprovalRow(
        approvalId: "ap2", tool: AgentCreateSummary.tool, title: "Create agent «Mailer»", command: "Mailer", diff: nil,
        reason: "agent: create", state: .pending,
        input: .object([
            "name": .string("Postfach-Überwachung für Rechnungen"), "role": .string("mail watcher"),
            "runtime": .string("claude"), "model": .string("claude-sonnet-5-5"), "approvalMode": .string("risky"),
            "capabilities": .array(["terminal", "files", "browser", "team", "screen"].map(JSONValue.string)),
            "integrations": .array([.string("Gmail"), .string("Notion")]), "integrationsAll": .bool(false),
            "schedules": .array([
                .object([
                    "title": .string("Eingehende Rechnungen prüfen"), "prompt": .string("Check the mail"),
                    "humanEn": .string("every 5 minutes"), "humanRu": .string("каждые 5 минут"),
                ])
            ]),
            "folder": .object(["mode": .string("existing"), "path": .string("/Users/someone/Documents/Projects/invoices")]),
            "instructions": .string(
                "Watch the mailbox every few minutes. Report each new invoice with its sender and amount, and never delete a letter."),
            "creator": .string("Forge"),
        ]))

    static let longQuickReplies = QuickReplies(
        buttons: [
            QuickReplyButton(label: "Postfach ist verbunden, weiter geht's", reply: "Verbunden"),
            QuickReplyButton(label: "Подключил почту, продолжай работу", reply: "Подключено"),
            QuickReplyButton(label: "1", reply: "Option 1"),
            QuickReplyButton(label: String(repeating: "W", count: 40), reply: "Option 2"),
        ],
        link: QuickReplyLink(label: "Gmail-Einstellungen öffnen und prüfen", url: "https://mail.google.com/mail/u/0/#settings"),
        progress: QuickReplyProgress(done: 2, total: 6), seq: 1)

    static let approvalViews: [AuditCase] = [
        // The card's own glow (a shadow) paints just beyond its box on purpose: no spill check. The width check still runs.
        AuditCase(name: "approval-card-narrow", width: 360, bleeds: true) { _ in
            AnyView(ApprovalCard(row: pendingApproval, agentName: "Forge", onDecide: { _, _ in }))
        },
        AuditCase(name: "approval-card", width: 560, bleeds: true) { _ in
            AnyView(ApprovalCard(row: pendingApproval, agentName: "Forge", onDecide: { _, _ in }))
        },
        // An agent asks to create another one: the longest card of the thread, with every row filled.
        AuditCase(name: "approval-create-narrow", width: 360, bleeds: true) { _ in
            AnyView(ApprovalCard(row: createApproval, agentName: "Forge", onDecide: { _, _ in }))
        },
        AuditCase(name: "approval-create", width: 560, bleeds: true) { _ in
            AnyView(ApprovalCard(row: createApproval, agentName: "Forge", onDecide: { _, _ in }))
        },
        AuditCase(name: "approval-create-answered", width: 360) { _ in
            AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    ApprovalCard(row: createApproval.with(.approved(by: .user, remember: false)), agentName: "Forge", onDecide: { _, _ in })
                    ApprovalCard(row: createApproval.with(.denied(by: .user)), agentName: "Forge", onDecide: { _, _ in })
                    ApprovalCard(row: createApproval.with(.denied(by: .policy)), agentName: "Forge", onDecide: { _, _ in })
                })
        },
        // Quick replies under the last message: four buttons with the longest labels, a link and the count.
        AuditCase(name: "quick-replies-narrow", width: 360) { _ in
            AnyView(QuickRepliesBar(replies: longQuickReplies, onReply: { _ in }, onOpen: { _ in }))
        },
        AuditCase(name: "quick-replies", width: 700) { _ in
            AnyView(QuickRepliesBar(replies: longQuickReplies, onReply: { _ in }, onOpen: { _ in }))
        },
        // The agent's details with the approval mode's hint under the choice (the longest hint: Risky only).
        AuditCase(name: "agent-inspector-approvals", width: 360, scrolls: true) { env in
            AnyView(DetailsTab(server: env.server, agent: movingAgent))
        },
    ]

    /// Renders every case in German and Russian into `LAYOUT_AUDIT_DIR` (skipped when it is not set, so CI stays fast) and
    /// fails, naming the view, for each one whose content needs more width than its container has or draws outside it.
    /// Text that is cut inside a box, or hidden behind another element, is not found by numbers: look at the pictures.
    @Test(.enabled(if: LayoutAudit.outputDirectory != nil)) func gallery() throws {
        let directory = try #require(LayoutAudit.outputDirectory)
        var findings: [AuditFinding] = []
        for language in Self.languages {
            L10n.withLanguageForTests(language) {
                for item in Self.cases {
                    findings.append(LayoutAudit.audit(item, language: language, into: directory))
                }
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

private extension ApprovalRow {
    /// The same request in another state.
    func with(_ state: ApprovalState) -> ApprovalRow {
        var copy = self
        copy.state = state
        return copy
    }
}
