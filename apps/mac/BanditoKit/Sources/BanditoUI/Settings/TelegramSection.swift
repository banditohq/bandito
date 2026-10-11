import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Telegram: the bot that carries approvals and agent replies to a phone, and the chats linked to it.
/// The status is read when the section opens and again whenever the daemon says it changed.
struct TelegramSection: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        if let server = app.currentServer {
            TelegramServerPage(server: server)
        } else {
            SettingsPage(title: SettingsSection.telegram.title, intro: L10n.Settings.Telegram.intro) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.Server.noServer)
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                    // Same action as Settings → Servers.
                    Button(L10n.Settings.Servers.add) {
                        router.sheet = .addServer
                    }
                    .banditoButton(.signal())
                }
            }
        }
    }
}

/// The section for one server: reads its status, and after each change reads the status again.
private struct TelegramServerPage: View {
    let server: ServerModel
    @State private var status: TelegramStatus?
    @State private var loadError: UserFacingMessage?

    var body: some View {
        TelegramPage(status: status, loadError: loadError, actions: actions)
            .task(id: server.id) {
                status = nil
                await load()
            }
            .onChange(of: server.telegramRevision) { _, _ in
                Task { await load() }
            }
    }

    private var actions: TelegramActions {
        let server = server
        return TelegramActions(
            setToken: { token in
                _ = try await server.telegramSetToken(token)
                await load()
            },
            removeToken: {
                try await server.telegramRemoveToken()
                await load()
            },
            linkStart: {
                try await server.telegramLinkStart()
            },
            unlink: { chatId in
                try await server.telegramUnlink(chatId: chatId)
                await load()
            },
            updateChat: { chatId, approvals, answers in
                try await server.telegramUpdateChat(chatId: chatId, approvals: approvals, answers: answers)
                await load()
            })
    }

    private func load() async {
        do {
            status = try await server.telegramStatus()
            loadError = nil
        } catch {
            loadError = UserFacingError.message(for: error)
        }
    }
}

/// What the page can ask for. The section passes each call to the server; the previews pass stand-ins.
struct TelegramActions {
    var setToken: @MainActor (String) async throws -> Void
    var removeToken: @MainActor () async throws -> Void
    var linkStart: @MainActor () async throws -> TelegramLink
    var unlink: @MainActor (Int64) async throws -> Void
    var updateChat: @MainActor (Int64, Bool?, TelegramAnswers?) async throws -> Void

    /// Does nothing and makes a link that lasts ten minutes: for the previews.
    static var preview: TelegramActions {
        TelegramActions(
            setToken: { _ in },
            removeToken: {},
            linkStart: {
                TelegramLink(
                    code: "ABCD2345", url: "https://t.me/bandito_dev_bot?start=ABCD2345",
                    expiresAt: TelegramRules.milliseconds(Date()) + 600_000)
            },
            unlink: { _ in },
            updateChat: { _, _, _ in })
    }
}

/// The Telegram section for one status. It holds the form state (the token field, the busy flag, the failure) and sends
/// each change through `actions`. It does not talk to a server itself, so the previews can show every state.
struct TelegramPage: View {
    let status: TelegramStatus?
    var loadError: UserFacingMessage?
    let actions: TelegramActions

    @State private var draft = ""
    /// A request is running: the controls are off, and a second click sends nothing.
    @State private var busy = false
    @State private var failure: TelegramFailure?
    @State private var confirmRemove = false
    @State private var linking = false
    /// The chats that existed when the link sheet opened. A chat that is not in this set closes the sheet.
    @State private var knownChatIDs: Set<Int64> = []

    var body: some View {
        SettingsPage(title: SettingsSection.telegram.title, intro: L10n.Settings.Telegram.intro) {
            VStack(alignment: .leading, spacing: 16) {
                if let loadError {
                    UserFacingErrorView(message: loadError)
                }
                if let status {
                    if status.configured {
                        connected(status)
                    } else {
                        setup
                    }
                } else if loadError == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            L10n.Settings.Telegram.removeConfirmTitle, isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button(L10n.Settings.Telegram.removeToken, role: .destructive) {
                run { try await actions.removeToken() }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Settings.Telegram.removeConfirmMessage)
        }
        .sheet(isPresented: $linking) {
            TelegramLinkSheet(isPresented: $linking, request: actions.linkStart)
        }
        .onChange(of: status) { _, now in
            // The sheet waits for a chat: once one shows up in the status, the link is in and the sheet goes.
            if linking, let now, TelegramRules.hasNewChat(known: knownChatIDs, current: now.chats) {
                linking = false
            }
        }
    }

    /// No token yet: the two steps, the token field and Connect.
    private var setup: some View {
        SettingsGroup(title: L10n.Settings.Telegram.bot) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Settings.Telegram.step1)
                    Text(L10n.Settings.Telegram.step2)
                }
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                SecureField(L10n.Settings.Telegram.tokenPlaceholder, text: $draft)
                    .banditoField(error: failure != nil)
                    .font(BanditoFont.mono(size: 13, weight: 400))
                    .disabled(busy)
                    .onSubmit { connect() }
                HStack(spacing: 10) {
                    Button(L10n.Settings.Telegram.connect) { connect() }
                        .banditoButton(.signal())
                        .disabled(!TelegramRules.canConnect(draft: draft, busy: busy))
                        .fixedSize()
                    if busy {
                        ProgressView().controlSize(.small)
                        Text(L10n.Settings.Telegram.checking)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    Spacer(minLength: 0)
                }
                if let failure {
                    UserFacingErrorView(message: failure.message)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A token is saved: the bot with its state, and the chats with their settings.
    private func connected(_ status: TelegramStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(title: L10n.Settings.Telegram.bot) {
                let stateText = status.running ? L10n.Settings.Telegram.stateRunning : L10n.Settings.Telegram.stateStopped
                SettingsRow(
                    title: status.bot.map { "@\($0.username)" } ?? L10n.Settings.Telegram.bot,
                    hint: stateText,
                    icon: SettingsIcon(symbol: "paperplane.fill", tint: BanditoPalette.badgeTeal)
                ) { EmptyView() }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Settings.Telegram.removeHint) {
                    Button(L10n.Settings.Telegram.removeToken) { confirmRemove = true }
                        .banditoButton(.quiet(tone: .danger))
                        .disabled(busy)
                        .fixedSize()
                }
                if let message = failure?.message ?? TelegramRules.problem(of: status)?.message {
                    UserFacingErrorView(message: message)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            SettingsGroup(title: L10n.Settings.Telegram.chats) {
                SettingsRow(title: L10n.Settings.Telegram.linkHint) {
                    Button(L10n.Settings.Telegram.linkAction) { startLinking(status) }
                        .banditoButton(.signal())
                        .disabled(busy)
                        .fixedSize()
                }
                if status.chats.isEmpty {
                    Divider().padding(.horizontal, 16)
                    Text(L10n.Settings.Telegram.noChats)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                ForEach(status.chats) { chat in
                    Divider().padding(.horizontal, 16)
                    chatRows(chat)
                }
            }
        }
    }

    @ViewBuilder
    private func chatRows(_ chat: TelegramChat) -> some View {
        SettingsRow(
            title: chat.title.isEmpty ? String(chat.chatId) : chat.title,
            hint: L10n.Settings.Telegram.linkedAt(date: TelegramRules.linkedDate(chat.linkedAt))
        ) {
            Button(L10n.Settings.Telegram.unlink) {
                run { try await actions.unlink(chat.chatId) }
            }
            .banditoButton(.quiet())
            .disabled(busy)
            .fixedSize()
        }
        Divider().padding(.horizontal, 16)
        SettingsRow(
            title: L10n.Settings.Telegram.approvals, hint: L10n.Settings.Telegram.approvalsHint,
            keepsControlBeside: true
        ) {
            Toggle("", isOn: approvalsBinding(chat))
                .labelsHidden()
                .toggleStyle(BanditoToggleStyle())
                .disabled(busy)
        }
        Divider().padding(.horizontal, 16)
        SettingsRow(title: L10n.Settings.Telegram.answers, hint: L10n.Settings.Telegram.answersHint) {
            SegmentedPicker(
                selection: answersBinding(chat),
                options: [
                    (TelegramAnswers.all, L10n.Settings.Telegram.answerAll),
                    (TelegramAnswers.telegram, L10n.Settings.Telegram.answerFromTelegram),
                    (TelegramAnswers.none, L10n.Settings.Telegram.answerNone),
                ])
                .disabled(busy)
        }
    }

    private func approvalsBinding(_ chat: TelegramChat) -> Binding<Bool> {
        Binding(
            get: { chat.approvals },
            set: { value in run { try await actions.updateChat(chat.chatId, value, nil) } })
    }

    private func answersBinding(_ chat: TelegramChat) -> Binding<TelegramAnswers> {
        Binding(
            get: { chat.answers },
            set: { value in run { try await actions.updateChat(chat.chatId, nil, value) } })
    }

    private func connect() {
        guard TelegramRules.canConnect(draft: draft, busy: busy) else { return }
        let token = TelegramRules.token(from: draft)
        run {
            try await actions.setToken(token)
            // Once saved, the token is no longer on screen.
            draft = ""
        }
    }

    private func startLinking(_ status: TelegramStatus) {
        knownChatIDs = Set(status.chats.map(\.chatId))
        linking = true
    }

    /// Runs one change. A call while one runs does nothing, so a double click is one request. A failure is shown in the
    /// section, never in an alert.
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                try await work()
            } catch {
                failure = TelegramRules.failure(for: error)
            }
            busy = false
        }
    }
}

/// The sheet with a link code: a QR code to scan with the phone, and a button that opens the link in Telegram on this
/// Mac. The code lives ten minutes. When it runs out, the sheet offers a new one. The page closes the sheet when the
/// chat is linked.
struct TelegramLinkSheet: View {
    @Binding var isPresented: Bool
    let request: @MainActor () async throws -> TelegramLink

    @State private var link: TelegramLink?
    @State private var requesting = false
    @State private var expired = false
    @State private var failure: TelegramFailure?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Settings.Telegram.linkAction)
                .font(BanditoFont.display(size: 18, weight: 600))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Settings.Telegram.Link.intro)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            content
                .frame(maxWidth: .infinity)
            if let failure {
                UserFacingErrorView(message: failure.message)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L10n.Common.close) { isPresented = false }
                    .banditoButton(.quiet())
                if expired {
                    Button(L10n.Settings.Telegram.Link.renew) { Task { await issue() } }
                        .banditoButton(.signal())
                        .disabled(requesting)
                } else if let link, let url = URL(string: link.url) {
                    Button(L10n.Settings.Telegram.Link.open) { SystemActions.open(url) }
                        .banditoButton(.signal())
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .task { await issue() }
        .task(id: link?.expiresAt) { await watchExpiry() }
    }

    @ViewBuilder
    private var content: some View {
        if expired {
            Text(L10n.Settings.Telegram.Link.expired)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
        } else if let link {
            VStack(spacing: 12) {
                QRCodeView(text: link.url, size: 200)
                TelegramCountdown(expiresAt: link.expiresAt)
                Text(L10n.Settings.Telegram.Link.waiting)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
        } else if requesting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10n.Settings.Telegram.Link.preparing)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            }
        }
    }

    private func issue() async {
        guard !requesting else { return }
        requesting = true
        link = nil
        expired = false
        failure = nil
        defer { requesting = false }
        do {
            link = try await request()
        } catch {
            failure = TelegramRules.failure(for: error)
        }
    }

    /// Flags the code as expired when its time runs out. A new code restarts the wait (the task is keyed on `expiresAt`).
    private func watchExpiry() async {
        guard let link else { return }
        let wait = TelegramRules.remainingMs(until: link.expiresAt, now: TelegramRules.milliseconds(Date()))
        try? await Task.sleep(for: .milliseconds(wait))
        if !Task.isCancelled {
            expired = true
        }
    }
}

/// The time a link code has left, counted down once a second. Only this view redraws on each tick.
struct TelegramCountdown: View {
    let expiresAt: Int64

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(text(at: context.date))
                .font(BanditoFont.text(size: 12, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .monospacedDigit()
        }
    }

    private func text(at date: Date) -> String {
        let left = TelegramRules.remainingMs(until: expiresAt, now: TelegramRules.milliseconds(date))
        return L10n.Settings.Telegram.Link.expiresIn(time: TelegramRules.countdown(remainingMs: left))
    }
}

#Preview("Telegram: not set up") {
    TelegramPage(
        status: TelegramStatus(configured: false, bot: nil, running: false, lastError: nil, chats: []),
        actions: .preview)
        .frame(width: 640, height: 560)
        .background(Color.Bandito.surface1)
        .preferredColorScheme(.dark)
}

#Preview("Telegram: set up, no chats") {
    TelegramPage(
        status: TelegramStatus(
            configured: true, bot: TelegramBot(username: "bandito_dev_bot", name: "Bandito"),
            running: true, lastError: nil, chats: []),
        actions: .preview)
        .frame(width: 640, height: 560)
        .background(Color.Bandito.surface1)
        .preferredColorScheme(.dark)
}

#Preview("Telegram: two chats, conflict") {
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
        actions: .preview)
        .frame(width: 640, height: 760)
        .background(Color.Bandito.surface1)
        .preferredColorScheme(.dark)
}
