import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// "Report a problem": what happened, what was expected, and the diagnostics. The whole report is shown, with the
/// secrets already hidden (`SecretRedactor`), and can be edited before it goes anywhere. It goes to GitHub as a link
/// that opens the issue form in the browser (`ProblemReport.link`): Bandito has no server for it and holds no token.
struct ReportProblemSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var what = ""
    @State private var expected = ""
    @State private var attach = true
    @State private var collecting = true
    /// The diagnostics, read once when the sheet opens, and the words of this Mac the redactor hides.
    @State private var diagnostics: ProblemDiagnostics?
    @State private var redactor = SecretRedactor()
    /// The diagnostics as the report shows them (redacted once, not at each letter typed).
    @State private var diagnosticsText: String?
    /// The text in the editor, and the text the fields made last: when they differ the person edited the report, and a
    /// change in the fields no longer replaces it.
    @State private var report = ""
    @State private var generated = ""
    @State private var notice: String?

    var body: some View {
        let _ = PerfCounters.hit("ReportProblemSheet")
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(L10n.Report.what, placeholder: L10n.Report.whatPlaceholder, text: $what, height: 84)
                    field(L10n.Report.expected, placeholder: L10n.Report.expectedPlaceholder, text: $expected, height: 56)
                    attachRow
                    previewBlock
                }
                .padding(24)
            }
            .scrollIndicators(.never)
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            footer
        }
        .frame(width: 640, height: 640)
        .background(Color.Bandito.surface2)
        .task {
            regenerate()
            await collect()
        }
        .onChange(of: what) { _, _ in regenerate() }
        .onChange(of: expected) { _, _ in regenerate() }
        .onChange(of: attach) { _, _ in
            rebuildDiagnosticsText()
            regenerate()
        }
    }

    // MARK: parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.Report.title)
                .font(BanditoFont.display(size: 18.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
            Text(L10n.Report.subtitle)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BanditoFont.text(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .banditoEditor()
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: height)
        }
    }

    private var attachRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Report.attach)
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Report.attachHint)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $attach)
                .labelsHidden()
                .toggleStyle(BanditoToggleStyle())
                .fixedSize()
        }
    }

    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.Report.preview)
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                if collecting && attach {
                    ProgressView().controlSize(.small)
                    Text(L10n.Report.collecting)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if report != generated {
                    Button(L10n.Report.reset) {
                        report = generated
                    }
                    .banditoButton(.link)
                    .fixedSize()
                }
            }
            Text(L10n.Report.previewHint)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            SourceEditor(text: $report, highlightsMarkdown: true, isEditable: true)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let notice {
                Text(notice)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ActionRow(hugging: notice != nil) {
                Button(L10n.Common.cancel) { dismiss() }
                    .banditoButton(.quiet())
                    .fixedSize()
                Button(L10n.Report.copy) { copyReport() }
                    .banditoButton(.quiet())
                    .disabled(waiting)
                    .fixedSize()
                Button(L10n.Report.openGitHub) { openOnGitHub() }
                    .banditoButton(.signal())
                    .disabled(waiting)
                    .fixedSize()
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: report

    /// The diagnostics are still being read and the report is to carry them.
    private var waiting: Bool { collecting && attach }

    private func collect() async {
        let result = await ProblemDiagnosticsCollector.collect(app: app)
        redactor = SecretRedactor(terms: result.terms)
        diagnostics = result.diagnostics
        rebuildDiagnosticsText()
        collecting = false
        regenerate()
    }

    private func rebuildDiagnosticsText() {
        diagnosticsText = attach ? diagnostics?.text(redactor: redactor) : nil
    }

    /// The report from the fields. Written to the editor only while the person has not edited it.
    private func regenerate() {
        let next = ProblemReport.text(
            what: redactor.redact(what), expected: redactor.redact(expected), diagnostics: diagnosticsText)
        guard next != generated else { return }
        if report == generated { report = next }
        generated = next
    }

    private func copyReport() {
        SystemActions.copy(report)
        notice = L10n.Report.copied
    }

    private func openOnGitHub() {
        guard let link = ProblemReport.link(report: report) else { return }
        if let clipboard = link.clipboard {
            SystemActions.copy(clipboard)
            notice = L10n.Report.clipboardNote
        }
        SystemActions.open(link.url)
    }
}
