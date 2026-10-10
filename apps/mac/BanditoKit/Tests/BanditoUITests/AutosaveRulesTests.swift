@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Autosave: when the viewer writes by itself, and when the side-by-side view is allowed.
@Suite struct AutosaveRulesTests {
    @Test func dirtyEditableTextIsSaved() {
        #expect(AutosaveRules.decision(isDirty: true, readOnly: false, hasConflict: false, isSaving: false) == .save)
    }

    @Test func cleanTextHasNothingToSave() {
        #expect(AutosaveRules.decision(isDirty: false, readOnly: false, hasConflict: false, isSaving: false) == .skip)
        #expect(AutosaveRules.decision(isDirty: false, readOnly: false, hasConflict: false, isSaving: true) == .skip)
    }

    @Test func readOnlyIsNeverSaved() {
        #expect(AutosaveRules.decision(isDirty: true, readOnly: true, hasConflict: false, isSaving: false) == .skip)
    }

    @Test func aConflictIsNeverWrittenOver() {
        #expect(AutosaveRules.decision(isDirty: true, readOnly: false, hasConflict: true, isSaving: false) == .skip)
        #expect(AutosaveRules.decision(isDirty: true, readOnly: false, hasConflict: true, isSaving: true) == .skip)
    }

    @Test func aRunningSaveMakesTheNextOneWait() {
        #expect(AutosaveRules.decision(isDirty: true, readOnly: false, hasConflict: false, isSaving: true) == .wait)
    }

    @Test func splitNeedsSevenTwentyPoints() {
        #expect(!ViewerLayoutRules.allowsSplit(width: 0))
        #expect(!ViewerLayoutRules.allowsSplit(width: 719.5))
        #expect(ViewerLayoutRules.allowsSplit(width: 720))
        #expect(ViewerLayoutRules.effectiveMode(.split, width: 500) == .edit)
        #expect(ViewerLayoutRules.effectiveMode(.split, width: 900) == .split)
        #expect(ViewerLayoutRules.effectiveMode(.read, width: 500) == .read)
        #expect(ViewerLayoutRules.effectiveMode(.edit, width: 500) == .edit)
    }
}

@MainActor
@Suite struct FileDocumentAutosaveTests {
    private func document() -> BanditoUI.FileDocument {
        BanditoUI.FileDocument(
            entry: FsEntry(
                name: "a.md", path: "/m/a.md", kind: .file, size: 0, modifiedMs: 0,
                hidden: false, readonly: false, symlinkTarget: nil, ext: "md"))
    }

    /// Without a server (never loaded) a flush returns at once: no spinning, no write, the text stays.
    @Test func flushWithoutAServerReturnsAndKeepsTheText() async {
        let doc = document()
        doc.replaceText("hello")
        await doc.flush()
        #expect(doc.isDirty)
        #expect(!doc.needsAttention)
    }
}
