import BanditoKit
import BanditoL10n
import Foundation

/// The words and small rules of a form card. Pure functions, so the card stays a layout.
public enum FormPresentation {
    /// A choice with this many options or fewer is a list of radio rows; more are a select field.
    public static let radioLimit = 4

    public static func usesRadio(_ field: FormField) -> Bool {
        field.type == .choice && (field.options?.count ?? 0) <= radioLimit
    }

    /// The sentence under a field whose value cannot be sent.
    public static func text(for problem: FormProblem) -> String {
        switch problem {
        case .required: L10n.Form.errRequired
        case .notAnEmail: L10n.Form.errEmail
        case .notANumber: L10n.Form.errNumber
        case .notADate: L10n.Form.errDate
        case .tooLong: L10n.Form.errTooLong
        case .notAnOption: L10n.Form.errOption
        }
    }

    /// A value as the card shows it in the summary of an answer.
    public static func display(_ value: JSONValue, field: FormField?) -> String {
        switch value {
        case .string(let s):
            if field?.type == .date, let date = FormDates.date(from: s) {
                return date.formatted(date: .abbreviated, time: .omitted)
            }
            return s
        case .number(let n):
            return FormAnswer.numberText(n)
        case .bool(let b):
            return b ? L10n.Form.yes : L10n.Form.no
        case .array(let items):
            return items.map { display($0, field: field) }.joined(separator: ", ")
        case .null:
            return ""
        case .object:
            return ""
        }
    }

    /// The answered fields in the form's order, as (label, value) pairs; fields without an answer are left out.
    public static func answerRows(spec: FormSpec, values: [String: JSONValue]) -> [(label: String, value: String)] {
        spec.fields.compactMap { field in
            guard let value = values[field.id] else { return nil }
            let shown = display(value, field: field)
            return shown.isEmpty ? nil : (field.label, shown)
        }
    }

    /// `A: x · B: y`, for the one-line summary of a submitted form.
    public static func summary(spec: FormSpec, values: [String: JSONValue]) -> String {
        answerRows(spec: spec, values: values).map { "\($0.label): \($0.value)" }.joined(separator: " · ")
    }

    /// The line a finished form is folded into.
    public static func line(spec: FormSpec, outcome: FormOutcome) -> String {
        switch outcome {
        case .submitted(let values):
            if spec.kind == .confirm { return L10n.Form.confirmed }
            let summary = summary(spec: spec, values: values)
            return summary.isEmpty ? L10n.Form.answered : L10n.Form.answeredLine(summary: summary)
        case .rejected(let comment):
            let why = comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if spec.kind == .confirm {
                return why.isEmpty ? L10n.Form.rejected : L10n.Form.rejectedWhy(comment: why)
            }
            return why.isEmpty ? L10n.Form.skipped : L10n.Form.skippedWhy(comment: why)
        case .expired:
            return L10n.Form.expired
        }
    }

    /// The label of the main button: the agent's own words when it gave some, else Send or Confirm.
    public static func submitTitle(_ spec: FormSpec) -> String {
        custom(spec.submitLabel) ?? (spec.kind == .confirm ? L10n.Form.confirm : L10n.Form.submit)
    }

    /// The label of the other button: the agent's own words, else Skip or Reject.
    public static func rejectTitle(_ spec: FormSpec) -> String {
        custom(spec.rejectLabel) ?? (spec.kind == .confirm ? L10n.Form.reject : L10n.Form.skip)
    }

    private static func custom(_ label: String?) -> String? {
        let t = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// What to say when `forms.answer` fails. A form that is over has its own sentence; the rest go through the
    /// general mapper.
    public static func message(for error: Error) -> UserFacingMessage {
        if let rpc = error as? RPCError {
            switch rpc.message {
            case "already_answered": return UserFacingMessage(text: L10n.Form.alreadyAnswered)
            case "expired": return UserFacingMessage(text: L10n.Form.expiredError)
            default: break
            }
        }
        return UserFacingError.message(for: error)
    }
}

/// Dates of a form: the wire has `YYYY-MM-DD`, the picker has a `Date` at the person's own calendar day.
public enum FormDates {
    public static func date(from text: String, calendar: Calendar = .current) -> Date? {
        guard FormAnswer.isDate(text) else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    public static func string(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
