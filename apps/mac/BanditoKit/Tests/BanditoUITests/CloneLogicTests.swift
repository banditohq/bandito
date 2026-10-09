import Testing

@testable import BanditoUI

@Suite struct CloneLogicTests {
    @Test func destinationIsTheNameInsideTheFolderOnScreen() {
        #expect(CloneLogic.destination(parent: "/home/me/code", name: "billing") == "/home/me/code/billing")
        #expect(CloneLogic.destination(parent: "/", name: "billing") == "/billing")
    }

    @Test func folderNameMustBeOnePlainName() {
        #expect(CloneLogic.isValidName("billing"))
        #expect(CloneLogic.isValidName("my-app.v2"))
        #expect(!CloneLogic.isValidName(""))
        #expect(!CloneLogic.isValidName("   "))
        #expect(!CloneLogic.isValidName("a/b"))
        #expect(!CloneLogic.isValidName("."))
        #expect(!CloneLogic.isValidName(".."))
    }
}
