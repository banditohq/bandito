import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// What a try came to.
enum ToolTryOutcome {
    case answer(ToolCallResult)
    case failure(UserFacingMessage)
}

/// "Try" for one tool: a form made from the tool's schema, Run, and the answer under it. A tool that is not marked as
/// only reading asks first, naming the service.
struct ToolTryView: View {
    let tool: IntegrationTool
    let service: String
    var run: (JSONValue) async -> ToolTryOutcome

    @State private var values: ToolForm.Values
    @State private var problems: [String: ToolForm.Problem] = [:]
    @State private var running = false
    @State private var confirming: JSONValue?
    @State private var outcome: ToolTryOutcome?
    private let form: ToolForm

    init(tool: IntegrationTool, service: String, run: @escaping (JSONValue) async -> ToolTryOutcome) {
        self.tool = tool
        self.service = service
        self.run = run
        let form = ToolForm(schema: tool.inputSchema)
        self.form = form
        _values = State(initialValue: form.initialValues)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            fields
            HStack(spacing: 10) {
                Button(running ? L10n.Market.Try.running : L10n.Market.Try.run, action: submit)
                    .banditoButton(.lightPill())
                    .disabled(running)
                    .fixedSize()
            }
            if let outcome {
                ToolTryResultView(outcome: outcome)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
        .confirmationDialog(
            L10n.Market.Try.confirmTitle(tool: tool.name),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { arguments in
            Button(L10n.Market.Try.run) { start(arguments) }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.Market.Try.confirmMessage(service: service))
        }
    }

    // MARK: fields

    @ViewBuilder
    private var fields: some View {
        switch form.shape {
        case .none:
            Text(L10n.Market.Try.noArguments)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
        case .object:
            fieldBox(
                title: L10n.Market.Try.rawLabel, name: ToolForm.rawName, required: false, summary: nil
            ) {
                jsonEditor(ToolForm.rawName)
            }
        case .fields(let list):
            ForEach(list) { field in
                fieldBox(title: field.name, name: field.name, required: field.required, summary: field.summary) {
                    editor(field)
                }
            }
        }
    }

    private func fieldBox<Content: View>(
        title: String, name: String, required: Bool, summary: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(BanditoFont.mono(size: 12, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                if required {
                    Chip(text: L10n.Market.Try.required, tone: .neutral)
                }
            }
            if let summary {
                Text(summary)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
            if let problem = problems[name] {
                Text(Self.text(problem))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
        }
    }

    @ViewBuilder
    private func editor(_ field: ToolForm.Field) -> some View {
        let failed = problems[field.name] != nil
        switch field.kind {
        case .string, .number, .integer:
            TextField(field.name, text: binding(field.name))
                .banditoField(error: failed)
                .disabled(running)
        case .boolean:
            BanditoSelect(
                selection: binding(field.name),
                sections: [
                    SelectSection(options: [
                        SelectOption(value: "", title: L10n.Market.Try.notSet),
                        SelectOption(value: "true", title: L10n.Market.Try.yes),
                        SelectOption(value: "false", title: L10n.Market.Try.no),
                    ])
                ],
                label: field.name, placeholder: L10n.Market.Try.choose
            )
            .disabled(running)
        case .choice(let options):
            BanditoSelect(
                selection: binding(field.name),
                sections: [
                    SelectSection(
                        options: [SelectOption(value: "", title: L10n.Market.Try.notSet)]
                            + options.enumerated().map { index, value in
                                SelectOption(value: String(index), title: ToolForm.label(of: value))
                            })
                ],
                label: field.name, placeholder: L10n.Market.Try.choose
            )
            .disabled(running)
        case .json:
            jsonEditor(field.name)
        }
    }

    private func jsonEditor(_ name: String) -> some View {
        TextField("{}", text: binding(name), axis: .vertical)
            .lineLimit(2...8)
            .banditoField(error: problems[name] != nil)
            .font(BanditoFont.mono(size: 12.5, weight: 400))
            .disabled(running)
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { text in
                values[name] = text
                // Editing a field clears what was said about it.
                if problems[name] != nil { problems[name] = nil }
            })
    }

    static func text(_ problem: ToolForm.Problem) -> String {
        switch problem {
        case .required: L10n.Market.Try.Problem.required
        case .notNumber: L10n.Market.Try.Problem.notNumber
        case .notInteger: L10n.Market.Try.Problem.notInteger
        case .notChoice: L10n.Market.Try.Problem.notChoice
        case .invalidJSON: L10n.Market.Try.Problem.invalidJson
        case .notObject: L10n.Market.Try.Problem.notObject
        }
    }

    // MARK: run

    private func submit() {
        guard !running else { return }
        switch form.arguments(from: values) {
        case .failure(let rejected):
            problems = rejected.problems
        case .success(let arguments):
            problems = [:]
            // A tool that is not known to only read changes something: the owner says yes first.
            if tool.readOnly { start(arguments) } else { confirming = arguments }
        }
    }

    private func start(_ arguments: JSONValue) {
        guard !running else { return }
        running = true
        outcome = nil
        Task {
            let result = await run(arguments)
            outcome = result
            running = false
        }
    }
}

/// The answer of a try: the text in monospace in a box of limited height, and the structured part as JSON.
struct ToolTryResultView: View {
    let outcome: ToolTryOutcome

    var body: some View {
        switch outcome {
        case .failure(let message):
            UserFacingErrorView(message: message)
        case .answer(let result):
            VStack(alignment: .leading, spacing: 10) {
                if result.isError {
                    Label {
                        Text(L10n.Market.Try.toolError)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
                }
                let text = ToolResultText.text(result)
                let structured = ToolResultText.structured(result)
                if text.isEmpty && structured == nil {
                    Text(L10n.Market.Try.emptyResult)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
                if !text.isEmpty {
                    box(title: L10n.Market.Try.result, text: text, failed: result.isError)
                }
                if let structured {
                    box(title: L10n.Market.Try.structured, text: structured, failed: false)
                }
            }
        }
    }

    private func box(title: String, text: String, failed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(BanditoFont.text(size: 11.5, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
            ScrollView {
                Text(text)
                    .font(BanditoFont.mono(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 220)
            .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(failed ? Color.Bandito.danger.opacity(0.6) : Color.Bandito.line, lineWidth: 1))
        }
    }
}
