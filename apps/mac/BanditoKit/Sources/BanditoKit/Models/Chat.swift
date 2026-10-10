import Foundation

// Forms, reactions and replies: the wire shapes of docs/ARCHITECTURE.md#forms, #reactions and
// #replies-and-attachments. Decoded with `.convertFromSnakeCase`.

// MARK: - Forms

public enum FormKind: String, ForwardCompatibleEnum, CaseIterable {
    /// Questions for the person; the agent goes on with the answers.
    case question
    /// A confirmation before something leaves the server: the fields are an editable summary.
    case confirm

    public static var fallback: FormKind { .question }
}

public enum FormFieldType: String, ForwardCompatibleEnum, CaseIterable {
    case text, textarea, email, number, choice, multichoice, boolean, date

    /// A type this app does not know is asked as plain text.
    public static var fallback: FormFieldType { .text }
}

public struct FormField: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var type: FormFieldType
    /// Only for `choice` and `multichoice`.
    public var options: [String]?
    public var isRequired: Bool
    /// The value the form starts with, as the agent wrote it.
    public var defaultValue: JSONValue?
    public var placeholder: String?
    public var help: String?

    private enum CodingKeys: String, CodingKey {
        case id, label, type, options, placeholder, help
        case isRequired = "required"
        case defaultValue = "default"
    }

    public init(
        id: String, label: String, type: FormFieldType, options: [String]? = nil, isRequired: Bool = false,
        defaultValue: JSONValue? = nil, placeholder: String? = nil, help: String? = nil
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.options = options
        self.isRequired = isRequired
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.help = help
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        type = try c.decodeIfPresent(FormFieldType.self, forKey: .type) ?? .text
        options = try c.decodeIfPresent([String].self, forKey: .options)
        isRequired = try c.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
        defaultValue = try c.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        help = try c.decodeIfPresent(String.self, forKey: .help)
    }
}

/// The form as the agent wrote it (the payload of `form_requested`, and `spec` of `forms.list`).
public struct FormSpec: Codable, Sendable, Hashable {
    public var title: String
    public var intro: String?
    public var kind: FormKind
    public var fields: [FormField]
    public var submitLabel: String?
    public var rejectLabel: String?

    public init(
        title: String, intro: String? = nil, kind: FormKind = .question, fields: [FormField],
        submitLabel: String? = nil, rejectLabel: String? = nil
    ) {
        self.title = title
        self.intro = intro
        self.kind = kind
        self.fields = fields
        self.submitLabel = submitLabel
        self.rejectLabel = rejectLabel
    }

    public init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case title, intro, kind, fields, submitLabel, rejectLabel }
        let c = try decoder.container(keyedBy: Keys.self)
        title = try c.decode(String.self, forKey: .title)
        intro = try c.decodeIfPresent(String.self, forKey: .intro)
        kind = try c.decodeIfPresent(FormKind.self, forKey: .kind) ?? .question
        fields = try c.decodeIfPresent([FormField].self, forKey: .fields) ?? []
        submitLabel = try c.decodeIfPresent(String.self, forKey: .submitLabel)
        rejectLabel = try c.decodeIfPresent(String.self, forKey: .rejectLabel)
    }
}

/// How a form ended (`action` of `form_answered`).
public enum FormAction: String, ForwardCompatibleEnum, CaseIterable {
    case submit, reject, expired

    /// A way of ending this app does not know has closed the form all the same: `expired` offers no answer.
    public static var fallback: FormAction { .expired }
}

/// The end of a form, as the thread keeps it.
public enum FormOutcome: Sendable, Hashable {
    case submitted(values: [String: JSONValue])
    case rejected(comment: String?)
    case expired
}

/// A form in the thread. `outcome` is nil while the form waits for the person.
public struct FormRow: Sendable, Hashable {
    public var formId: String
    public var spec: FormSpec
    public var outcome: FormOutcome?
    /// Unix milliseconds of the request.
    public var ts: Int64

    public init(formId: String, spec: FormSpec, outcome: FormOutcome? = nil, ts: Int64) {
        self.formId = formId
        self.spec = spec
        self.outcome = outcome
        self.ts = ts
    }

    public var isPending: Bool { outcome == nil }
}

/// A form as `forms.list` returns it.
public struct FormRecord: Decodable, Sendable, Hashable {
    public var id: String
    public var agentId: String
    public var status: String
    public var spec: FormSpec
    public var createdAt: Int64
}

enum FormKeys {
    /// How the RPC decoder spells a dictionary key that was `id` on the wire. The decoder turns `snake_case` keys into
    /// camelCase everywhere, including the keys of `values`, so a field `to_address` comes back as `toAddress`.
    static func decodedSpelling(of id: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [id: 0]),
            let decoded = try? RPCClient.decoder.decode([String: Int].self, from: data),
            let key = decoded.keys.first
        else { return id }
        return key
    }

    /// `values` with the keys the form's fields have: an answer decoded by the RPC decoder is put back to the ids.
    static func restoring(_ values: [String: JSONValue], fields: [FormField]) -> [String: JSONValue] {
        var spelled: [String: String] = [:]
        for field in fields { spelled[decodedSpelling(of: field.id)] = field.id }
        var out: [String: JSONValue] = [:]
        for (key, value) in values {
            let id = fields.contains(where: { $0.id == key }) ? key : (spelled[key] ?? key)
            out[id] = value
        }
        return out
    }
}

// MARK: - Answering a form

/// What the person has put into one field. The form view keeps one per field; `FormAnswer` checks them.
public enum FormInput: Sendable, Hashable {
    case text(String)
    case flag(Bool)
    /// The chosen option of a `choice`, if any.
    case option(String?)
    /// The chosen options of a `multichoice`, in the order of the field's options.
    case options([String])
    /// A date as `YYYY-MM-DD`, if one is set.
    case date(String?)
}

/// Why a field's value cannot be sent. The view words each one.
public enum FormProblem: Sendable, Hashable {
    case required
    case notAnEmail
    case notANumber
    case notADate
    /// A text longer than the daemon takes (8 KB).
    case tooLong
    /// A value that is not one of the options.
    case notAnOption
}

/// The checks of a form's answer, the same the daemon makes (daemon/src/forms.rs), so a mistake is shown at the
/// field and not as a refusal from the server. Pure functions.
public enum FormAnswer {
    /// The longest text of a `text` or `textarea` field, in bytes.
    public static let maxTextBytes = 8 * 1024
    public static let maxCommentBytes = 4 * 1024

    /// The form's first state: each field's default, or an empty value of its type.
    public static func initialInputs(for spec: FormSpec) -> [String: FormInput] {
        var inputs: [String: FormInput] = [:]
        for field in spec.fields { inputs[field.id] = initialInput(for: field) }
        return inputs
    }

    public static func initialInput(for field: FormField) -> FormInput {
        let fallback = field.defaultValue
        switch field.type {
        case .text, .textarea, .email:
            return .text(fallback?.string ?? "")
        case .number:
            if case .number(let n)? = fallback { return .text(numberText(n)) }
            return .text(fallback?.string ?? "")
        case .boolean:
            if case .bool(let b)? = fallback { return .flag(b) }
            return .flag(false)
        case .choice:
            return .option(fallback?.string)
        case .multichoice:
            if case .array(let items)? = fallback {
                let picked = Set(items.compactMap(\.string))
                return .options((field.options ?? []).filter(picked.contains))
            }
            return .options([])
        case .date:
            return .date(fallback?.string)
        }
    }

    /// `3` for 3.0, and the shortest exact text for the rest.
    public static func numberText(_ n: Double) -> String {
        if n.rounded() == n, abs(n) < 9.0e15 { return String(Int64(n)) }
        return String(n)
    }

    /// The number a field's text means: a comma is accepted as the decimal mark when there is no dot.
    public static func parseNumber(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.contains("."), t.filter({ $0 == "," }).count == 1 { t = t.replacingOccurrences(of: ",", with: ".") }
        guard let n = Double(t), n.isFinite else { return nil }
        return n
    }

    /// An address the daemon takes: no spaces, and something on both sides of the first `@`.
    public static func isEmail(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let at = text.firstIndex(of: "@") else { return false }
        return at != text.startIndex && text.index(after: at) != text.endIndex
    }

    /// `YYYY-MM-DD` that is a real day.
    public static func isDate(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    /// The field started with a value that is not itself empty.
    static func hasDefault(_ field: FormField) -> Bool {
        switch field.defaultValue {
        case nil, .null?: return false
        case .string(let t)?: return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let a)?: return !a.isEmpty
        default: return true
        }
    }

    /// The value a field sends, or why it cannot. `nil` value with no problem means the field is left out (empty, not
    /// required, and without a default); with a default, an empty field sends `""` or `[]`.
    public static func value(of field: FormField, input: FormInput?) -> (value: JSONValue?, problem: FormProblem?) {
        // An empty optional field that started with a default sends its emptiness: left out, the daemon would put the
        // default back. A switch cannot be emptied.
        var cleared: JSONValue?
        if !field.isRequired, hasDefault(field) {
            switch field.type {
            case .multichoice: cleared = .array([])
            case .boolean: cleared = nil
            default: cleared = .string("")
            }
        }
        let empty: (value: JSONValue?, problem: FormProblem?) = (cleared, field.isRequired ? .required : nil)
        switch (field.type, input) {
        case (.text, .text(let t)?), (.textarea, .text(let t)?):
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return empty }
            if t.utf8.count > maxTextBytes { return (nil, .tooLong) }
            return (.string(t), nil)
        case (.email, .text(let raw)?):
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return empty }
            return isEmail(t) ? (.string(t), nil) : (nil, .notAnEmail)
        case (.number, .text(let t)?):
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return empty }
            guard let n = parseNumber(t) else { return (nil, .notANumber) }
            return (.number(n), nil)
        case (.boolean, .flag(let b)?):
            return (.bool(b), nil)
        case (.choice, .option(let o)?):
            guard let o, !o.isEmpty else { return empty }
            return (field.options ?? []).contains(o) ? (.string(o), nil) : (nil, .notAnOption)
        case (.multichoice, .options(let picked)?):
            if picked.isEmpty { return empty }
            let known = field.options ?? []
            if picked.contains(where: { !known.contains($0) }) { return (nil, .notAnOption) }
            return (.array(picked.map { JSONValue.string($0) }), nil)
        case (.date, .date(let d)?):
            guard let d, !d.isEmpty else { return empty }
            return isDate(d) ? (.string(d), nil) : (nil, .notADate)
        default:
            // No input of the field's kind (a form built by hand): the same as an empty field.
            return empty
        }
    }

    /// The problems of every field, by field id. Empty when the answer can be sent.
    public static func problems(spec: FormSpec, inputs: [String: FormInput]) -> [String: FormProblem] {
        var found: [String: FormProblem] = [:]
        for field in spec.fields {
            if let problem = value(of: field, input: inputs[field.id]).problem { found[field.id] = problem }
        }
        return found
    }

    /// The `values` of `forms.answer`: only the fields that have a value. Nil with the problems when one is wrong.
    public static func values(
        spec: FormSpec, inputs: [String: FormInput]
    ) -> Result<[String: JSONValue], FormProblems> {
        var out: [String: JSONValue] = [:]
        var found: [String: FormProblem] = [:]
        for field in spec.fields {
            let result = value(of: field, input: inputs[field.id])
            if let problem = result.problem {
                found[field.id] = problem
            } else if let value = result.value {
                out[field.id] = value
            }
        }
        return found.isEmpty ? .success(out) : .failure(FormProblems(byField: found))
    }

    /// A rejection comment the daemon takes: empty is no comment, and a long one is cut to its limit.
    public static func comment(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.utf8.count <= maxCommentBytes { return t }
        var cut = t
        while cut.utf8.count > maxCommentBytes { cut.removeLast() }
        return cut
    }

    /// The params of `forms.answer` as JSON bytes. Built by hand: the RPC encoder would rewrite the keys of `values`
    /// (a field `subjectLine` would be sent as `subject_line`).
    public static func answerParams(
        formId: String, action: FormAction, values: [String: JSONValue]? = nil, comment: String? = nil
    ) throws -> Data {
        var object: [String: Any] = ["form_id": formId, "action": action.rawValue]
        if let values {
            object["values"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(JSONValue.object(values)), options: .fragmentsAllowed)
        }
        if let comment { object["comment"] = comment }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

/// Problems of a form's fields, by field id (what `FormAnswer.values` returns when a field is wrong).
public struct FormProblems: Error, Sendable, Hashable {
    public var byField: [String: FormProblem]
}

// MARK: - Reactions and replies

public enum ReactionBy: String, ForwardCompatibleEnum, CaseIterable {
    case user, agent

    public static var fallback: ReactionBy { .agent }
}

/// A file a message carries (`attachments` of `message.user`): the same shape as the one the person uploads.
public typealias MessageAttachment = AgentAttachment

/// The reactions on one message: at most one by the person and one by the agent. Each side remembers the `seq` of the
/// event that set it, so that history read in pieces (a newer page first, an older page later) settles on the newest.
public struct MessageReactions: Sendable, Hashable {
    public struct Mark: Sendable, Hashable {
        /// Nil: the reaction was taken off.
        public var emoji: String?
        public var eventSeq: Int64
    }

    public var user: Mark?
    public var agent: Mark?

    public init() {}

    mutating func set(by: ReactionBy, emoji: String?, eventSeq: Int64) {
        let mark = Mark(emoji: emoji, eventSeq: eventSeq)
        switch by {
        case .user: if (user?.eventSeq ?? 0) <= eventSeq { user = mark }
        case .agent: if (agent?.eventSeq ?? 0) <= eventSeq { agent = mark }
        }
    }

    /// Keeps the newer mark of each side.
    mutating func merge(_ other: MessageReactions) {
        if let m = other.user { set(by: .user, emoji: m.emoji, eventSeq: m.eventSeq) }
        if let m = other.agent { set(by: .agent, emoji: m.emoji, eventSeq: m.eventSeq) }
    }

    /// The person's emoji, if one is on.
    public var mine: String? { user?.emoji }

    /// The reactions in view, each emoji once: with who put it there. The person's first.
    public var chips: [ReactionChip] {
        var out: [ReactionChip] = []
        let mineEmoji = user?.emoji
        let agentEmoji = agent?.emoji
        if let mineEmoji {
            out.append(ReactionChip(emoji: mineEmoji, byUser: true, byAgent: mineEmoji == agentEmoji))
        }
        if let agentEmoji, agentEmoji != mineEmoji {
            out.append(ReactionChip(emoji: agentEmoji, byUser: false, byAgent: true))
        }
        return out
    }
}

public struct ReactionChip: Sendable, Hashable, Identifiable {
    public var emoji: String
    public var byUser: Bool
    public var byAgent: Bool
    public var id: String { emoji }
}
