import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import Observation
import SwiftUI

/// The publish sheet of a bot or skill: the exact payload that goes out (collapsed), the visibility, the name, the
/// description and, for a skill, its license. After publishing: the link, Copy, and a QR code.
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        /// The payload is read from the daemon.
        case loading
        /// Ready to publish.
        case editing
        case published(ShareCreated)
        /// The payload could not be read (the daemon's answer is named in the text).
        case unavailable(String)
    }

    let subject: ShareSubject
    private(set) var phase: Phase = .loading
    private(set) var info: SharedPayloadInfo?
    private(set) var payload: JSONValue?
    var title = ""
    var summary = ""
    var visibility: ShareVisibility = .link
    var license = ShareLogic.defaultLicense
    var previewExpanded = false
    private(set) var inFlight = false
    private(set) var problem: String?

    /// `payload` is set when the payload is already known (previews); the defaults of the name and description follow.
    init(subject: ShareSubject, phase: Phase = .loading, payload: JSONValue? = nil) {
        self.subject = subject
        self.phase = phase
        if let payload, let parsed = SharedPayloadInfo(kind: subject.kind, payload: payload) {
            self.payload = payload
            info = parsed
            title = String(parsed.name.prefix(ShareLogic.titleLimit))
            summary = String((parsed.role ?? parsed.description ?? "").prefix(ShareLogic.summaryLimit))
        }
    }

    /// The payload as text for the collapsed preview: the exact JSON that is sent.
    var payloadText: String {
        payload.map(ShareLogic.payloadText) ?? ""
    }

    /// Reads the payload from the daemon. A skill's payload depends on its license, so it is read again when that changes.
    /// Edits made meanwhile (name, description) stay.
    func loadPayload(server: ServerModel) async {
        if case .published = phase { return }
        if payload == nil { phase = .loading }
        do {
            let exported: JSONValue
            switch subject {
            case .bot(let agentID):
                exported = try await server.exportBot(agentID: agentID)
            case .skill(let name):
                exported = try await server.exportSkill(name: name, license: license)
            }
            guard let parsed = SharedPayloadInfo(kind: kind, payload: exported) else {
                phase = .unavailable(L10n.Share.Problem.payload)
                return
            }
            payload = exported
            info = parsed
            if title.isEmpty { title = String(parsed.name.prefix(ShareLogic.titleLimit)) }
            if summary.isEmpty, let line = parsed.role ?? parsed.description {
                summary = String(line.prefix(ShareLogic.summaryLimit))
            }
            phase = .editing
        } catch let error as RPCError {
            phase = .unavailable(ShareLogic.installMessage(for: SharedInstallFailure(error)))
        } catch {
            phase = .unavailable(L10n.Share.Problem.payload)
        }
    }

    var kind: ShareKind { subject.kind }

    func canPublish(signedIn: Bool) -> Bool {
        ShareLogic.canPublish(
            title: title, summary: summary, hasPayload: payload != nil, signedIn: signedIn, inFlight: inFlight)
            && phase == .editing
    }

    /// Publishes once. A second call while the request runs does nothing. Records where the share came from, so
    /// "Update to the current version" can export again later.
    func publish(server: ServerModel, signedIn: Bool, client: () async throws -> AccountClient) async {
        guard canPublish(signedIn: signedIn), let payload else { return }
        inFlight = true
        problem = nil
        defer { inFlight = false }
        do {
            let draft = ShareDraft(
                kind: kind, visibility: visibility, lang: ModelDescription.currentLanguageCode,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), payload: payload)
            let created = try await client().createShare(draft)
            ShareSourceStore.remember(source(on: server), for: created.id)
            phase = .published(created)
        } catch let failure as ShareFailure {
            problem = ShareLogic.publishMessage(for: failure)
        } catch {
            problem = L10n.Share.Problem.generic
        }
    }

    private func source(on server: ServerModel) -> ShareSource {
        switch subject {
        case .bot(let agentID):
            ShareSource(kind: .bot, serverID: server.id.uuidString, agentID: agentID)
        case .skill(let name):
            ShareSource(kind: .skill, serverID: server.id.uuidString, skillName: name)
        }
    }
}

struct ShareSheet: View {
    let subject: ShareSubject
    /// Nil only in previews: the payload is read and the share is published on this server.
    let server: ServerModel?
    @Environment(AccountHub.self) private var accountHub
    @Environment(Router.self) private var router
    @State private var model: ShareModel
    @State private var copied = false

    init(subject: ShareSubject, server: ServerModel?, model: ShareModel? = nil) {
        self.subject = subject
        self.server = server
        _model = State(initialValue: model ?? ShareModel(subject: subject))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch model.phase {
            case .loading:
                Text(L10n.Share.Sheet.loading)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            case .unavailable(let message):
                Text(message)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            case .editing:
                if accountHub.signedIn {
                    form
                } else {
                    signInPrompt
                }
            case .published(let created):
                published(created)
            }
            if let problem = model.problem {
                Text(problem)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .published = model.phase {
                EmptyView()
            } else {
                buttons
            }
        }
        .padding(24)
        .frame(width: 480, alignment: .leading)
        .background(Color.Bandito.surface2)
        .task {
            if let server { await model.loadPayload(server: server) }
        }
        .onChange(of: model.license) { _, _ in
            guard model.kind == .skill, let server else { return }
            Task { await model.loadPayload(server: server) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.Share.Sheet.title)
                .font(BanditoFont.display(size: 18.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(ShareLogic.kindLabel(model.kind))
                .font(BanditoFont.text(size: 11, weight: 600))
                .foregroundStyle(Color.Bandito.text2)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Color.Bandito.text.opacity(0.06), in: Capsule())
            Spacer(minLength: 0)
        }
    }

    // MARK: form

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            preview
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel(L10n.Share.Visibility.title)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(ShareVisibility.allCases, id: \.self) { visibility in
                        RadioRow(
                            title: ShareLogic.visibilityLabel(visibility),
                            description: ShareLogic.visibilityHint(visibility),
                            badge: nil,
                            isSelected: model.visibility == visibility
                        ) { model.visibility = visibility }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(L10n.Share.Field.name)
                TextField("", text: $model.title)
                    .banditoField()
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(L10n.Share.Field.summary)
                TextField("", text: $model.summary, axis: .vertical)
                    .lineLimit(2...4)
                    .banditoField()
                if !ShareLogic.isSummaryValid(model.summary) {
                    Text(L10n.Share.Problem.summaryTooLong(limit: String(ShareLogic.summaryLimit)))
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.danger)
                }
            }
            if model.kind == .skill {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(L10n.Share.Field.license)
                    BanditoSelect(
                        selection: $model.license,
                        sections: [SelectSection(options: ShareLogic.licenses.map { SelectOption(value: $0, title: $0) })],
                        label: L10n.Share.Field.license, placeholder: ShareLogic.defaultLicense,
                        field: { SelectFieldView(option: $0, placeholder: ShareLogic.defaultLicense) },
                        footer: { _ in EmptyView() })
                }
            }
        }
    }

    private var signInPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Share.SignIn.hint)
                .font(BanditoFont.display(size: 15, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Share.SignIn.text)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.Share.SignIn.button) { router.sheet = .account }
                .banditoButton(.lightPill())
                .fixedSize()
        }
    }

    /// What goes out, exactly as the daemon exported it. Long text is cut to twelve lines until "Show all".
    private var preview: some View {
        let text = model.payloadText
        let shown = ShareLogic.preview(of: text)
        let body = model.previewExpanded ? text : shown.shown
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel(L10n.Share.Preview.title)
                Spacer(minLength: 0)
                if shown.isCollapsed {
                    Button(model.previewExpanded ? L10n.Share.Preview.collapse : L10n.Share.Preview.expand) {
                        model.previewExpanded.toggle()
                    }
                    .banditoButton(.link)
                }
            }
            ScrollView {
                Text(body)
                    .font(BanditoFont.mono(size: 11, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: model.previewExpanded ? 260 : nil)
            .padding(10)
            .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 11.5, weight: 600))
            .foregroundStyle(Color.Bandito.text3)
    }

    // MARK: after publishing

    private func published(_ created: ShareCreated) -> some View {
        let link = ShareLogic.pageURL(id: created.id)
        return VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Share.Done.title)
                .font(BanditoFont.display(size: 15, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(link)
                        .font(BanditoFont.mono(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Button(copied ? L10n.Share.Done.copied : L10n.Share.Done.copy) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        copied = true
                    }
                    .banditoButton(.lightPill())
                    .fixedSize()
                    Text(L10n.Share.Done.qrHint)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
                Spacer(minLength: 0)
                QRCodeView(text: link, size: 150)
            }
            Button(L10n.Share.Done.close) { router.sheet = nil }
                .banditoButton(.signal())
                .fixedSize()
        }
    }

    // MARK: buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 8)
            Button(L10n.Common.cancel) { router.sheet = nil }
                .banditoButton(.quiet())
            if accountHub.signedIn, case .editing = model.phase {
                Button(model.inFlight ? L10n.Share.Publish.publishing : L10n.Share.Publish.button) {
                    guard let server else { return }
                    Task {
                        await model.publish(
                            server: server, signedIn: accountHub.signedIn,
                            client: { try await accountHub.prepare() })
                    }
                }
                .banditoButton(.signal())
                .disabled(server == nil || !model.canPublish(signedIn: accountHub.signedIn))
            }
        }
    }
}

#Preview("Publish: before") {
    ShareSheet(subject: .bot(agentID: "agent-1"), server: nil, model: ShareSamples.publishDraft)
        .environment(AccountHub())
        .environment(Router())
        .padding(40)
        .background(Color.Bandito.bg)
}

#Preview("Publish: after") {
    ShareSheet(subject: .bot(agentID: "agent-1"), server: nil, model: ShareSamples.published)
        .environment(AccountHub())
        .environment(Router())
        .padding(40)
        .background(Color.Bandito.bg)
}
