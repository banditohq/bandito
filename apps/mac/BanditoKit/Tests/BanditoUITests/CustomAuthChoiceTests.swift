import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// "Своя интеграция": which sign-in the sheet offers for an address, and when "Добавить" checks it first.
@Suite struct CustomAuthChoiceTests {
    @Test func aServiceThatSignsInInTheBrowserGetsTheSignInInPlaceOfTheFields() {
        let signsIn = IntegrationTest(ok: false, oauth: true)
        #expect(CustomAuthChoice.of(kind: .http, test: signsIn, canSignIn: true) == .browserSignIn)
        // A daemon that cannot start the sign-in keeps the header fields.
        #expect(CustomAuthChoice.of(kind: .http, test: signsIn, canSignIn: false) == .headers)
        // A program never signs in in the browser.
        #expect(CustomAuthChoice.of(kind: .stdio, test: signsIn, canSignIn: true) == .headers)
    }

    @Test func aPlainFailureOrNoCheckKeepsTheHeaderFields() {
        let failed = IntegrationTest(ok: false, error: "the server answered with HTTP 500")
        #expect(CustomAuthChoice.of(kind: .http, test: failed, canSignIn: true) == .headers)
        #expect(CustomAuthChoice.of(kind: .http, test: nil, canSignIn: true) == .headers)
    }

    @Test func addChecksAnAddressNobodyHasCheckedYet() {
        #expect(CustomAuthChoice.checksBeforeAdd(kind: .http, test: nil, canSignIn: true))
        // A check that ran (with any answer) is not repeated.
        let ok = IntegrationTest(ok: true, tools: ["search"])
        let signsIn = IntegrationTest(ok: false, oauth: true)
        #expect(!CustomAuthChoice.checksBeforeAdd(kind: .http, test: ok, canSignIn: true))
        #expect(!CustomAuthChoice.checksBeforeAdd(kind: .http, test: signsIn, canSignIn: true))
        // An older daemon, or a program, saves as it always did.
        #expect(!CustomAuthChoice.checksBeforeAdd(kind: .http, test: nil, canSignIn: false))
        #expect(!CustomAuthChoice.checksBeforeAdd(kind: .stdio, test: nil, canSignIn: true))
    }
}
