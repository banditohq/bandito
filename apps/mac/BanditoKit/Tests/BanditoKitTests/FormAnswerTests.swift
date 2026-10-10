import Foundation
import Testing

@testable import BanditoKit

/// The checks a form's answer goes through before it is sent (the same as the daemon's, daemon/src/forms.rs).
@Suite struct FormAnswerTests {
    func field(
        _ type: FormFieldType, required: Bool = false, options: [String]? = nil, defaultValue: JSONValue? = nil
    ) -> FormField {
        FormField(id: "f", label: "F", type: type, options: options, isRequired: required, defaultValue: defaultValue)
    }

    func value(_ field: FormField, _ input: FormInput?) -> (value: JSONValue?, problem: FormProblem?) {
        FormAnswer.value(of: field, input: input)
    }

    @Test func textRules() {
        #expect(value(field(.text), .text("hi")).value == .string("hi"))
        // Empty and blank text is no answer; it is a problem only for a required field.
        #expect(value(field(.text), .text("  \n")).value == nil)
        #expect(value(field(.text), .text("")).problem == nil)
        #expect(value(field(.text, required: true), .text(" ")).problem == .required)
        #expect(value(field(.textarea), .text(String(repeating: "x", count: 8 * 1024 + 1))).problem == .tooLong)
        #expect(value(field(.textarea), .text(String(repeating: "x", count: 8 * 1024))).problem == nil)
        // Eight KB is counted in bytes: 4097 two-byte letters are too long.
        #expect(value(field(.text), .text(String(repeating: "я", count: 4097))).problem == .tooLong)
    }

    @Test func emailRules() {
        #expect(value(field(.email), .text("a@b.c")).value == .string("a@b.c"))
        #expect(value(field(.email), .text("  a@b.c ")).value == .string("a@b.c"))
        for bad in ["a", "@b.c", "a@", "a b@c.d", "a@b c"] {
            #expect(value(field(.email), .text(bad)).problem == .notAnEmail, "\(bad)")
        }
        #expect(value(field(.email), .text("")).problem == nil)
        #expect(value(field(.email, required: true), .text("")).problem == .required)
    }

    @Test func numberRules() {
        #expect(value(field(.number), .text("42")).value == .number(42))
        #expect(value(field(.number), .text(" -3.5 ")).value == .number(-3.5))
        // A comma is the decimal mark when there is no dot.
        #expect(value(field(.number), .text("3,5")).value == .number(3.5))
        for bad in ["abc", "1,2,3", "1.2.3", "nan", "inf", "12px"] {
            #expect(value(field(.number), .text(bad)).problem == .notANumber, "\(bad)")
        }
        #expect(value(field(.number), .text("")).value == nil)
        #expect(value(field(.number, required: true), .text("")).problem == .required)
    }

    @Test func booleanIsAlwaysAnAnswer() {
        #expect(value(field(.boolean), .flag(false)).value == .bool(false))
        #expect(value(field(.boolean, required: true), .flag(true)).value == .bool(true))
    }

    @Test func choiceRules() {
        let choice = field(.choice, options: ["red", "blue"])
        #expect(value(choice, .option("red")).value == .string("red"))
        #expect(value(choice, .option("green")).problem == .notAnOption)
        #expect(value(choice, .option(nil)).problem == nil)
        #expect(value(field(.choice, required: true, options: ["a"]), .option(nil)).problem == .required)
    }

    @Test func multichoiceRules() {
        let multi = field(.multichoice, options: ["a", "b", "c"])
        #expect(value(multi, .options(["a", "c"])).value == .array([.string("a"), .string("c")]))
        #expect(value(multi, .options(["a", "z"])).problem == .notAnOption)
        #expect(value(multi, .options([])).value == nil)
        #expect(value(field(.multichoice, required: true, options: ["a"]), .options([])).problem == .required)
    }

    @Test func dateRules() {
        #expect(value(field(.date), .date("2026-10-10")).value == .string("2026-10-10"))
        #expect(value(field(.date), .date("2026-02-30")).problem == .notADate)
        #expect(value(field(.date), .date("2026-2-3")).problem == .notADate)
        #expect(value(field(.date), .date("10.10.2026")).problem == .notADate)
        #expect(value(field(.date), .date("2028-02-29")).problem == nil)
        #expect(value(field(.date), .date("2027-02-29")).problem == .notADate)
        #expect(value(field(.date), .date(nil)).problem == nil)
        #expect(value(field(.date, required: true), .date(nil)).problem == .required)
    }

    @Test func clearingAFieldWithADefaultSendsTheEmptyValue() {
        #expect(value(field(.text, defaultValue: .string("Hi")), .text("")).value == .string(""))
        #expect(value(field(.textarea, defaultValue: .string("Hi")), .text("  ")).value == .string(""))
        #expect(value(field(.email, defaultValue: .string("a@b.c")), .text("")).value == .string(""))
        #expect(value(field(.date, defaultValue: .string("2026-10-10")), .date(nil)).value == .string(""))
        #expect(
            value(field(.multichoice, options: ["a", "b"], defaultValue: .array([.string("a")])), .options([])).value
                == .array([]))
        // Nothing to clear without a default, or with an empty one.
        #expect(value(field(.text), .text("")).value == nil)
        #expect(value(field(.text, defaultValue: .string("")), .text("")).value == nil)
        // A required field is still required; a switch cannot be emptied.
        #expect(value(field(.text, required: true, defaultValue: .string("Hi")), .text("")).problem == .required)
        #expect(value(field(.boolean, defaultValue: .bool(true)), .flag(false)).value == .bool(false))
    }

    @Test func theClearedFieldTravelsInTheAnswer() throws {
        let spec = FormSpec(title: "T", fields: [FormField(id: "t", label: "T", type: .text, defaultValue: .string("Hi"))])
        let values = try FormAnswer.values(spec: spec, inputs: ["t": .text("")]).get()
        #expect(values == ["t": .string("")])
    }

    @Test func aMissingInputIsAnEmptyField() {
        #expect(value(field(.text, required: true), nil).problem == .required)
        #expect(value(field(.text), nil).problem == nil)
        // An input of the wrong kind for the field is empty as well.
        #expect(value(field(.number, required: true), .flag(true)).problem == .required)
    }

    @Test func theFormStartsFromTheDefaults() {
        let spec = FormSpec(
            title: "T",
            fields: [
                FormField(id: "a", label: "A", type: .text, defaultValue: .string("x")),
                FormField(id: "n", label: "N", type: .number, defaultValue: .number(3)),
                FormField(id: "m", label: "M", type: .number, defaultValue: .number(2.5)),
                FormField(id: "b", label: "B", type: .boolean, defaultValue: .bool(true)),
                FormField(id: "b2", label: "B2", type: .boolean),
                FormField(id: "c", label: "C", type: .choice, options: ["p", "q"], defaultValue: .string("q")),
                FormField(
                    id: "d", label: "D", type: .multichoice, options: ["p", "q", "r"],
                    defaultValue: .array([.string("r"), .string("p")])),
                FormField(id: "e", label: "E", type: .date, defaultValue: .string("2026-01-02")),
                FormField(id: "z", label: "Z", type: .email),
            ])
        let inputs = FormAnswer.initialInputs(for: spec)
        #expect(inputs["a"] == .text("x"))
        #expect(inputs["n"] == .text("3"))
        #expect(inputs["m"] == .text("2.5"))
        #expect(inputs["b"] == .flag(true))
        #expect(inputs["b2"] == .flag(false))
        #expect(inputs["c"] == .option("q"))
        // In the order of the options, not of the default.
        #expect(inputs["d"] == .options(["p", "r"]))
        #expect(inputs["e"] == .date("2026-01-02"))
        #expect(inputs["z"] == .text(""))
        // The defaults are an acceptable answer as they are.
        #expect((try? FormAnswer.values(spec: spec, inputs: inputs).get()) != nil)
    }

    @Test func valuesLeaveOutEmptyFieldsAndNameTheProblems() throws {
        let spec = FormSpec(
            title: "T",
            fields: [
                FormField(id: "name", label: "Name", type: .text, isRequired: true),
                FormField(id: "note", label: "Note", type: .textarea),
                FormField(id: "mail", label: "Mail", type: .email),
            ])
        let ok = try FormAnswer.values(
            spec: spec, inputs: ["name": .text("Ann"), "note": .text(""), "mail": .text("")]
        ).get()
        #expect(ok == ["name": .string("Ann")])

        let bad = FormAnswer.values(spec: spec, inputs: ["name": .text(" "), "mail": .text("nope")])
        guard case .failure(let problems) = bad else { Issue.record("expected problems"); return }
        #expect(problems.byField == ["name": .required, "mail": .notAnEmail])
        #expect(FormAnswer.problems(spec: spec, inputs: ["name": .text("x")]).isEmpty)
    }

    @Test func aRejectionCommentIsTrimmedAndCut() {
        #expect(FormAnswer.comment("  ") == nil)
        #expect(FormAnswer.comment(" why ") == "why")
        let long = String(repeating: "я", count: 3000)
        let cut = FormAnswer.comment(long)
        #expect((cut?.utf8.count ?? 0) <= FormAnswer.maxCommentBytes)
        #expect(cut?.hasPrefix("яя") == true)
    }

    @Test func theAnswerKeepsTheFieldIdsAsTheyAre() throws {
        let data = try FormAnswer.answerParams(
            formId: "f1", action: .submit,
            values: ["subjectLine": .string("Hi"), "to_address": .string("a@b.c"), "n": .number(3), "ok": .bool(true)])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["form_id"] as? String == "f1")
        #expect(object["action"] as? String == "submit")
        let values = try #require(object["values"] as? [String: Any])
        // The RPC encoder would have sent `subject_line`.
        #expect(Set(values.keys) == ["subjectLine", "to_address", "n", "ok"])
        #expect(values["subjectLine"] as? String == "Hi")
        #expect(values["n"] as? Int == 3)
        #expect(values["ok"] as? Bool == true)
    }

    @Test func aRejectionCarriesItsComment() throws {
        let data = try FormAnswer.answerParams(formId: "f", action: .reject, comment: "later")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["action"] as? String == "reject")
        #expect(object["comment"] as? String == "later")
        #expect(object["values"] == nil)
    }

    @Test func theDecoderSpellingOfAnIdIsUndone() {
        let fields = [
            FormField(id: "to_address", label: "To", type: .email),
            FormField(id: "subject", label: "S", type: .text),
            FormField(id: "Plain-id", label: "P", type: .text),
        ]
        // Whether the decoder rewrites the keys of a dictionary depends on the system's Foundation; the test takes the
        // spelling it gives, whichever it is.
        let spelled = FormKeys.decodedSpelling(of: "to_address")
        let restored = FormKeys.restoring(
            [spelled: .string("a"), "subject": .string("b"), "Plain-id": .string("c"), "stranger": .null],
            fields: fields)
        #expect(Set(restored.keys) == ["to_address", "subject", "Plain-id", "stranger"])
        #expect(restored["to_address"] == .string("a"))
    }
}
