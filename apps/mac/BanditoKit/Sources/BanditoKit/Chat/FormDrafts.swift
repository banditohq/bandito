import Foundation
import Observation

/// What a person has typed into the forms that wait, by form id, and whether the answer has gone out. Kept apart from
/// the card so that a half-filled form stays when its row scrolls away and comes back, or the person goes to another
/// agent. A form's draft is dropped when the form is over.
@MainActor
@Observable
public final class FormDrafts {
    public static let shared = FormDrafts()

    public struct Draft: Equatable {
        public var inputs: [String: FormInput]
        /// The optional reason of a rejection.
        public var comment = ""
        /// The answer was sent and the daemon took it; the form's own event has not come yet.
        public var sent = false
    }

    public private(set) var drafts: [String: Draft] = [:]

    public init() {}

    /// The draft of a form: what was typed, or the form's first state.
    public func draft(for formId: String, spec: FormSpec) -> Draft {
        drafts[formId] ?? Draft(inputs: FormAnswer.initialInputs(for: spec))
    }

    public func setInput(_ input: FormInput, field: String, formId: String, spec: FormSpec) {
        var d = draft(for: formId, spec: spec)
        d.inputs[field] = input
        drafts[formId] = d
    }

    public func setComment(_ comment: String, formId: String, spec: FormSpec) {
        var d = draft(for: formId, spec: spec)
        d.comment = comment
        drafts[formId] = d
    }

    public func markSent(formId: String, spec: FormSpec) {
        var d = draft(for: formId, spec: spec)
        d.sent = true
        drafts[formId] = d
    }

    /// Drops the draft of a form that is over. Safe to call for a form with none.
    public func clear(formId: String) {
        if drafts[formId] != nil { drafts[formId] = nil }
    }
}
