import Testing

@testable import BanditoUI

/// Name and role in the inspector: the saved value comes in unless the person is typing in that field.
@Suite struct IdentityFieldTests {
    @Test func savedValueIsTakenWhenTheFieldIsNotBeingEdited() {
        #expect(IdentityField.text(current: "old", saved: "new", editing: false) == "new")
    }

    @Test func typedTextIsKeptWhileTheFieldHasFocus() {
        #expect(IdentityField.text(current: "half-typed", saved: "new", editing: true) == "half-typed")
    }
}
