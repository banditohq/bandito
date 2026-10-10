import CoreGraphics
import Testing

@testable import BanditoUI

/// Avatar color and face must be a pure function of the name: same name, same look, every launch.
@Suite struct RaccoonAvatarTests {
    @Test func stableHashIsFixedForForge() {
        // h = h * 31 + scalar over "Forge": a constant, not `hashValue` (which is seeded per process).
        #expect(stableNameHash("Forge") == 68_066_119)
    }

    @Test func forgeResolvesToFixedColorAndFace() {
        let resolved = AvatarResolver.resolve(name: "Forge", color: nil, face: .auto)
        #expect(resolved == ResolvedAvatar(color: .sky, face: .chevronDash))
    }

    @Test func sameNameGivesSameStyleAcrossCalls() {
        let names = ["Forge", "Scout", "Night Owl", "Watch", "Quill"]
        for name in names {
            let first = AvatarResolver.resolve(name: name, color: nil, face: .auto)
            let second = AvatarResolver.resolve(name: name, color: nil, face: .auto)
            #expect(first == second)
        }
    }

    @Test func distinctNamesGetDistinctColors() {
        let names = ["Forge", "Scout", "Night Owl", "Watch", "Quill"]
        let colors = Set(names.map { AvatarResolver.resolve(name: $0, color: nil, face: .auto).color })
        #expect(colors.count >= 3)
    }

    @Test func explicitColorAndFaceOverrideAutomaticChoice() {
        let resolved = AvatarResolver.resolve(name: "Forge", color: .rose, face: .dots)
        #expect(resolved == ResolvedAvatar(color: .rose, face: .dots))
    }

    @Test func resolvedFaceIsNeverAuto() {
        for name in ["Forge", "Scout", "Night Owl", "Watch", "Quill", ""] {
            let resolved = AvatarResolver.resolve(name: name, color: nil, face: .auto)
            #expect(resolved.face != .auto)
        }
    }

    @Test func pickerOffersNineFacesWithoutAuto() {
        #expect(AvatarFace.faces.count == 9)
        #expect(Set(AvatarFace.faces).count == 9)
        #expect(!AvatarFace.faces.contains(.auto))
    }

    /// Every offered face draws something: strokes, dots, or both. Only `.dots` has no stroke, only the closed
    /// faces have no dots.
    @Test func everyOfferedFaceDrawsItsParts() {
        let box = CGRect(x: 0, y: 0, width: DesignGrid.edge, height: DesignGrid.edge)
        for face in AvatarFace.faces {
            let strokes = RaccoonFaceStrokes(face: face).path(in: box)
            let dots = RaccoonFaceDots(face: face).path(in: box)
            #expect(!(strokes.isEmpty && dots.isEmpty), "face \(face.rawValue) draws nothing")
        }
    }

    @Test func dotFacesHaveDotsAndClosedFacesDoNot() {
        let box = CGRect(x: 0, y: 0, width: DesignGrid.edge, height: DesignGrid.edge)
        for face in [AvatarFace.dots, .wink, .serious, .glasses] {
            #expect(!RaccoonFaceDots(face: face).path(in: box).isEmpty, "\(face.rawValue) has no dots")
        }
        for face in [AvatarFace.carets, .chevronDash, .happy, .surprised, .sleeping] {
            #expect(RaccoonFaceDots(face: face).path(in: box).isEmpty, "\(face.rawValue) has dots")
        }
    }

    @Test func newFaceWireNamesAreStable() {
        #expect(AvatarFace(rawValue: "wink") == .wink)
        #expect(AvatarFace(rawValue: "surprised") == .surprised)
        #expect(AvatarFace(rawValue: "sleeping") == .sleeping)
        #expect(AvatarFace(rawValue: "glasses") == .glasses)
        #expect(AvatarFace(rawValue: "happy") == .happy)
        #expect(AvatarFace(rawValue: "serious") == .serious)
    }
}
