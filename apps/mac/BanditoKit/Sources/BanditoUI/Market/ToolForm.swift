import BanditoKit
import Foundation

/// The form of "Try" for one tool, built from the tool's `input_schema` (a JSON schema). A field is a string, a number,
/// an integer, a yes or no, or one of a list of values; whatever else (an array, an object, a choice of shapes, a nested
/// object) is a field of JSON text that is checked before it is sent. Pure, so the form and the arguments it makes are
/// easy to test.
struct ToolForm: Equatable {
    enum Kind: Equatable {
        case string
        case number
        case integer
        case boolean
        /// One of these values (strings, numbers, yes or no).
        case choice([JSONValue])
        /// JSON text.
        case json
    }

    struct Field: Identifiable, Equatable {
        var name: String
        var kind: Kind
        var required: Bool
        /// The schema's own words about the field.
        var summary: String?
        /// What the schema offers to start with, as the field shows it.
        var initial: String
        var id: String { name }
    }

    /// How the form takes the arguments.
    enum Shape: Equatable {
        /// One field for each property of the schema.
        case fields([Field])
        /// The tool takes no arguments.
        case none
        /// The schema is missing or is not a plain object schema: the arguments are typed as one JSON object.
        case object
    }

    var shape: Shape

    /// Why a field's text cannot be used.
    enum Problem: Error, Equatable {
        case required
        case notNumber
        case notInteger
        case notChoice
        case invalidJSON
        /// The raw JSON of a form with no fields must be an object.
        case notObject
    }

    /// Every field that cannot be used, by name.
    struct Rejected: Error, Equatable {
        var problems: [String: Problem]
    }

    /// The text of the fields as the person left them, by field name. A yes or no is `"true"`, `"false"` or empty
    /// (not set). A choice holds the index of the value in its list, or empty.
    typealias Values = [String: String]

    /// The name of the one field of the `.object` shape.
    static let rawName = "arguments"

    // MARK: from a schema

    init(schema: JSONValue?) {
        guard let schema, case .object(let root) = schema else {
            shape = .object
            return
        }
        // `type` may be missing on a schema that lists `properties`; any other type is not an object.
        let type = Self.primaryType(root["type"])
        guard type == nil || type == "object", case .object(let properties)? = root["properties"] else {
            // An object schema with no properties takes no arguments; anything else is typed by hand.
            shape = (type == "object" && root["properties"] == nil && root["anyOf"] == nil && root["oneOf"] == nil
                && root["allOf"] == nil) ? .none : .object
            return
        }
        guard !properties.isEmpty else {
            shape = .none
            return
        }
        var required: Set<String> = []
        if case .array(let list)? = root["required"] {
            required = Set(list.compactMap(\.string))
        }
        let fields = properties.map { name, value in
            Self.field(name: name, schema: value, required: required.contains(name))
        }
        // Required fields first, then by name.
        shape = .fields(
            fields.sorted { a, b in
                a.required != b.required ? a.required : a.name.localizedStandardCompare(b.name) == .orderedAscending
            })
    }

    /// The first type that is not `null`: `type` is a name or a list of names (`["string", "null"]`).
    private static func primaryType(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let name)?: return name
        case .array(let names)?: return names.compactMap(\.string).first { $0 != "null" }
        default: return nil
        }
    }

    private static func field(name: String, schema: JSONValue, required: Bool) -> Field {
        let summary = (schema["description"]?.string ?? schema["title"]?.string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var kind: Kind
        if case .array(let values)? = schema["enum"], !values.isEmpty, values.allSatisfy(isScalar) {
            kind = .choice(values)
        } else if schema["anyOf"] != nil || schema["oneOf"] != nil || schema["allOf"] != nil {
            kind = .json
        } else {
            switch primaryType(schema["type"]) {
            case "string": kind = .string
            case "number": kind = .number
            case "integer": kind = .integer
            case "boolean": kind = .boolean
            default: kind = .json
            }
        }
        var initial = ""
        if let fallback = schema["default"] {
            initial = text(of: fallback, kind: kind)
        }
        return Field(
            name: name, kind: kind, required: required, summary: summary?.isEmpty == false ? summary : nil,
            initial: initial)
    }

    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .string, .number, .bool: true
        default: false
        }
    }

    /// A schema's default as the field shows it.
    private static func text(of value: JSONValue, kind: Kind) -> String {
        switch (kind, value) {
        case (.string, .string(let s)): return s
        case (.number, .number(let n)), (.integer, .number(let n)): return number(n)
        case (.boolean, .bool(let b)): return b ? "true" : "false"
        case (.choice(let options), _): return options.firstIndex(of: value).map(String.init) ?? ""
        case (.json, _): return json(value) ?? ""
        default: return ""
        }
    }

    static func number(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    }

    /// How a choice's value reads in the list.
    static func label(of value: JSONValue) -> String {
        switch value {
        case .string(let s): s
        case .number(let n): number(n)
        case .bool(let b): b ? "true" : "false"
        default: ""
        }
    }

    // MARK: the values

    /// The text each field starts with.
    var initialValues: Values {
        guard case .fields(let fields) = shape else { return [:] }
        return Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.initial) })
    }

    /// The arguments the values make, or what is wrong with which field. Empty optional fields are left out; an empty
    /// required one is a problem.
    func arguments(from values: Values) -> Result<JSONValue, Rejected> {
        switch shape {
        case .none:
            return .success(.object([:]))
        case .object:
            let text = (values[Self.rawName] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return .success(.object([:])) }
            guard let parsed = Self.parse(text) else { return .failure(Rejected(problems: [Self.rawName: .invalidJSON])) }
            guard case .object = parsed else { return .failure(Rejected(problems: [Self.rawName: .notObject])) }
            return .success(parsed)
        case .fields(let fields):
            var out: [String: JSONValue] = [:]
            var problems: [String: Problem] = [:]
            for field in fields {
                let raw = values[field.name] ?? ""
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                switch Self.value(of: field, text: text, raw: raw) {
                case .success(let value?): out[field.name] = value
                case .success(nil): if field.required { problems[field.name] = .required }
                case .failure(let problem): problems[field.name] = problem
                }
            }
            return problems.isEmpty ? .success(.object(out)) : .failure(Rejected(problems: problems))
        }
    }

    /// The value of one field; nil when it is empty.
    private static func value(of field: Field, text: String, raw: String) -> Result<JSONValue?, Problem> {
        if text.isEmpty {
            // An empty field is left out; a required one is then a problem.
            return .success(nil)
        }
        switch field.kind {
        case .string:
            // The string as typed, with its spaces: only the empty check looked at the trimmed text.
            return .success(.string(raw))
        case .number:
            guard let n = Double(text), n.isFinite else { return .failure(.notNumber) }
            return .success(.number(n))
        case .integer:
            guard let n = Int64(text) else { return .failure(.notInteger) }
            return .success(.number(Double(n)))
        case .boolean:
            switch text {
            case "true": return .success(.bool(true))
            case "false": return .success(.bool(false))
            default: return .failure(.notChoice)
            }
        case .choice(let options):
            guard let index = Int(text), options.indices.contains(index) else { return .failure(.notChoice) }
            return .success(options[index])
        case .json:
            guard let parsed = parse(text) else { return .failure(.invalidJSON) }
            return .success(parsed)
        }
    }

    // MARK: JSON text

    /// JSON text as a value; nil when it is not JSON. A bare value (a number, a word in quotes) is allowed.
    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
            let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return value(from: any)
    }

    private static func value(from any: Any) -> JSONValue? {
        switch any {
        case is NSNull: return .null
        case let number as NSNumber:
            // `true` and `false` are numbers to Foundation; its own type tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let string as String: return .string(string)
        case let list as [Any]: return .array(list.compactMap(value(from:)))
        case let object as [String: Any]: return .object(object.compactMapValues(value(from:)))
        default: return nil
        }
    }

    /// A value as indented JSON text, keys in order; nil if it cannot be written.
    static func json(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder.pretty.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension JSONEncoder {
    /// Indented, keys sorted: for showing a value, not for the wire.
    fileprivate static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

/// What "Try" says about the answer of a tool: its text, its structured part, and whether the tool called it an error.
enum ToolResultText {
    /// The text parts, one under the other; a part that is not text is named by its type, in brackets.
    static func text(_ result: ToolCallResult) -> String {
        result.content.map { part in
            part.text ?? "[\(part.type)]"
        }.joined(separator: "\n\n")
    }

    /// The text part as it is shown: a JSON object or array as indented JSON (two spaces, keys sorted), anything else
    /// as it came. A number or a quoted string is left alone, so its text is never rewritten.
    static func display(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] || value is [Any],
              let pretty = try? JSONSerialization.data(
                  withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8)
        else { return text }
        return string
    }

    /// The structured part as indented JSON.
    static func structured(_ result: ToolCallResult) -> String? {
        result.structured.flatMap(ToolForm.json)
    }
}
