import Testing

@testable import BanditoUI

/// The name of a new folder is checked before the daemon is asked to create it.
@Suite struct NewFolderNameTests {
    @Test func emptyAndBlankNamesAreEmpty() {
        #expect(FolderPickerLogic.newFolderProblem("") == .empty)
        #expect(FolderPickerLogic.newFolderProblem("   ") == .empty)
    }

    @Test func slashDotAndDotDotAreInvalid() {
        #expect(FolderPickerLogic.newFolderProblem("a/b") == .invalid)
        #expect(FolderPickerLogic.newFolderProblem("/") == .invalid)
        #expect(FolderPickerLogic.newFolderProblem(".") == .invalid)
        #expect(FolderPickerLogic.newFolderProblem("..") == .invalid)
        #expect(FolderPickerLogic.newFolderProblem(" .. ") == .invalid)
    }

    @Test func plainNamesAreAcceptedIncludingDotFiles() {
        #expect(FolderPickerLogic.newFolderProblem("New folder") == nil)
        #expect(FolderPickerLogic.newFolderProblem(".cache") == nil)
        #expect(FolderPickerLogic.newFolderProblem("  app  ") == nil)
    }

    @Test func everyProblemHasAMessage() {
        #expect(!FolderPickerLogic.NewFolderProblem.empty.message.isEmpty)
        #expect(!FolderPickerLogic.NewFolderProblem.invalid.message.isEmpty)
    }
}
