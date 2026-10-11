import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// "Try": the form made from a tool's schema, and the arguments it makes.
@Suite struct ToolFormTests {
    private func schema(_ raw: String) throws -> JSONValue {
        try RPCClient.decoder.decode(JSONValue.self, from: Data(raw.utf8))
    }

    private func form(_ raw: String) throws -> ToolForm {
        ToolForm(schema: try schema(raw))
    }

    private func fields(_ form: ToolForm) -> [ToolForm.Field] {
        guard case .fields(let list) = form.shape else { return [] }
        return list
    }

    private func arguments(_ form: ToolForm, _ values: ToolForm.Values) -> JSONValue? {
        if case .success(let value) = form.arguments(from: values) { return value }
        return nil
    }

    private func problems(_ form: ToolForm, _ values: ToolForm.Values) -> [String: ToolForm.Problem] {
        if case .failure(let rejected) = form.arguments(from: values) { return rejected.problems }
        return [:]
    }

    private let sample = ##"""
        {"type":"object","required":["title","count"],"properties":{
          "title":{"type":"string","description":"The title."},
          "count":{"type":"integer"},
          "ratio":{"type":"number","default":0.5},
          "urgent":{"type":"boolean"},
          "state":{"type":"string","enum":["open","closed"],"default":"open"},
          "labels":{"type":"array","items":{"type":"string"}},
          "meta":{"type":"object","properties":{"a":{"type":"string"}}},
          "either":{"anyOf":[{"type":"string"},{"type":"number"}]},
          "maybe":{"type":["string","null"]}
        }}
        """##

    // MARK: building the form

    @Test func eachPropertyBecomesAFieldOfItsKind() throws {
        let list = fields(try form(sample))
        func kind(_ name: String) -> ToolForm.Kind? { list.first { $0.name == name }?.kind }
        #expect(kind("title") == .string)
        #expect(kind("count") == .integer)
        #expect(kind("ratio") == .number)
        #expect(kind("urgent") == .boolean)
        #expect(kind("state") == .choice([.string("open"), .string("closed")]))
        // Arrays, nested objects and choices of shape are JSON text.
        #expect(kind("labels") == .json)
        #expect(kind("meta") == .json)
        #expect(kind("either") == .json)
        // A type that is a list takes the first one that is not null.
        #expect(kind("maybe") == .string)
    }

    @Test func requiredFieldsComeFirstAndAreMarked() throws {
        let list = fields(try form(sample))
        #expect(list.prefix(2).map(\.name) == ["count", "title"])
        #expect(list.filter(\.required).map(\.name) == ["count", "title"])
        #expect(list.first { $0.name == "title" }?.summary == "The title.")
        #expect(list.first { $0.name == "urgent" }?.summary == nil)
    }

    @Test func defaultsStartTheFieldsAndAnEnumDefaultIsTheIndex() throws {
        let f = try form(sample)
        let initial = f.initialValues
        #expect(initial["ratio"] == "0.5")
        #expect(initial["state"] == "0")
        #expect(initial["title"] == "")
    }

    @Test func aSchemaWithoutPropertiesTakesNoArguments() throws {
        #expect(try form(#"{"type":"object","properties":{}}"#).shape == .none)
        #expect(try form(#"{"type":"object"}"#).shape == .none)
        #expect(arguments(try form(#"{"type":"object"}"#), [:]) == .object([:]))
    }

    @Test func anOddOrMissingSchemaIsTypedAsOneJSONObject() throws {
        #expect(ToolForm(schema: nil).shape == .object)
        #expect(try form(#"{"type":"string"}"#).shape == .object)
        #expect(try form(#"{"oneOf":[{"type":"object"}]}"#).shape == .object)
        let raw = ToolForm(schema: nil)
        #expect(arguments(raw, [:]) == .object([:]))
        #expect(arguments(raw, [ToolForm.rawName: #"{"a": 1}"#]) == .object(["a": .number(1)]))
        #expect(problems(raw, [ToolForm.rawName: "{oops"]) == [ToolForm.rawName: .invalidJSON])
        #expect(problems(raw, [ToolForm.rawName: "[1]"]) == [ToolForm.rawName: .notObject])
    }

    // MARK: the arguments

    @Test func theArgumentsAreMadeFromTheTextOfTheFields() throws {
        let f = try form(sample)
        let made = arguments(
            f,
            [
                "title": "  Fix the login ", "count": "3", "ratio": "0.25", "urgent": "true", "state": "1",
                "labels": #"["a","b"]"#, "meta": #"{"a":"x"}"#, "either": "7", "maybe": "",
            ])
        #expect(
            made
                == .object([
                    "title": .string("  Fix the login "),
                    "count": .number(3),
                    "ratio": .number(0.25),
                    "urgent": .bool(true),
                    "state": .string("closed"),
                    "labels": .array([.string("a"), .string("b")]),
                    "meta": .object(["a": .string("x")]),
                    "either": .number(7),
                ]))
    }

    @Test func emptyOptionalFieldsAreLeftOut() throws {
        let f = try form(sample)
        let made = arguments(f, ["title": "x", "count": "1", "ratio": "", "urgent": "", "state": ""])
        #expect(made == .object(["title": .string("x"), "count": .number(1)]))
    }

    @Test func aRequiredFieldLeftEmptyIsAProblem() throws {
        let found = problems(try form(sample), ["title": "   ", "count": ""])
        #expect(found == ["title": .required, "count": .required])
    }

    @Test func textThatDoesNotFitItsKindIsNamed() throws {
        let f = try form(sample)
        let found = problems(
            f,
            [
                "title": "x", "count": "1.5", "ratio": "abc", "urgent": "maybe", "state": "9", "labels": "[1,",
                "meta": "nope",
            ])
        #expect(found["count"] == .notInteger)
        #expect(found["ratio"] == .notNumber)
        #expect(found["urgent"] == .notChoice)
        #expect(found["state"] == .notChoice)
        #expect(found["labels"] == .invalidJSON)
        #expect(found["meta"] == .invalidJSON)
        #expect(found["title"] == nil)
        // Nothing is sent while a field has a problem.
        #expect(arguments(f, ["title": "x", "count": "1.5"]) == nil)
    }

    @Test func numbersAcceptSignsAndRefuseNotANumber() throws {
        let f = try form(#"{"type":"object","properties":{"n":{"type":"number"},"i":{"type":"integer"}}}"#)
        #expect(arguments(f, ["n": "-2.5", "i": "-7"]) == .object(["n": .number(-2.5), "i": .number(-7)]))
        #expect(problems(f, ["n": "nan"]) == ["n": .notNumber])
        #expect(problems(f, ["n": "inf"]) == ["n": .notNumber])
        #expect(problems(f, ["i": "1e3"]) == ["i": .notInteger])
    }

    @Test func aChoiceOfNumbersAndYesNoKeepsItsType() throws {
        let f = try form(#"{"type":"object","properties":{"level":{"enum":[1,2,3]},"on":{"enum":[true,false]}}}"#)
        let list = fields(f)
        #expect(list.first { $0.name == "level" }?.kind == .choice([.number(1), .number(2), .number(3)]))
        #expect(arguments(f, ["level": "1", "on": "1"]) == .object(["level": .number(2), "on": .bool(false)]))
        #expect(ToolForm.label(of: .number(2)) == "2")
        #expect(ToolForm.label(of: .bool(true)) == "true")
    }

    @Test func anEnumWithAnObjectInItIsJSONText() throws {
        let f = try form(#"{"type":"object","properties":{"x":{"enum":[{"a":1}]}}}"#)
        #expect(fields(f).first?.kind == .json)
    }

    @Test func jsonTextKeepsBareValuesAndBooleansApart() throws {
        let f = try form(#"{"type":"object","properties":{"v":{}}}"#)
        #expect(arguments(f, ["v": "true"]) == .object(["v": .bool(true)]))
        #expect(arguments(f, ["v": "1"]) == .object(["v": .number(1)]))
        #expect(arguments(f, ["v": #""text""#]) == .object(["v": .string("text")]))
        #expect(arguments(f, ["v": "null"]) == .object(["v": .null]))
    }

    // MARK: the answer

    @Test func theAnswerIsShownAsTextAndAsJSON() {
        let result = ToolCallResult(
            content: [ToolContentPart(type: "text", text: "one"), ToolContentPart(type: "image"), ToolContentPart(type: "text", text: "two")],
            structured: .object(["b": .number(2), "a": .string("x/y")]))
        #expect(ToolResultText.text(result) == "one\n\n[image]\n\ntwo")
        let json = ToolResultText.structured(result)
        #expect(json?.contains("\"a\" : \"x/y\"") == true, "keys sorted, slashes left alone: \(json ?? "")")
        #expect(ToolResultText.structured(ToolCallResult()) == nil)
        #expect(ToolResultText.text(ToolCallResult()) == "")
    }
}
