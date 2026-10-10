import AppKit
import BanditoDesign
import CoreText
import Testing

/// The three bundled faces: registered, found by name, and used by the right role.
@Suite struct BrandFontsTests {
    init() {
        BanditoFont.registerBundledFonts()
    }

    @Test func bundledFontsRegister() {
        #expect(BanditoFont.registerBundledFonts())
    }

    @Test(arguments: ["Unbounded-Regular", "Onest-Regular", "JetBrainsMono-Regular"])
    func fontIsFoundByName(name: String) {
        #expect(NSFont(name: name, size: 14) != nil)
    }

    @Test func rolesReturnTheirFamilies() {
        let display = BanditoFont.ctFont(family: BanditoFont.displayFamily, size: 14, weight: 600)
        let text = BanditoFont.ctFont(family: BanditoFont.textFamily, size: 14, weight: 400)
        let mono = BanditoFont.ctFont(family: BanditoFont.monoFamily, size: 14, weight: 400)
        #expect(CTFontCopyFamilyName(display) as String == "Unbounded")
        #expect(CTFontCopyFamilyName(text) as String == "Onest")
        #expect(CTFontCopyFamilyName(mono) as String == "JetBrains Mono")
        #expect(BanditoFont.appKitMono(size: 12).familyName == "JetBrains Mono")
        #expect(BanditoFont.appKitText(size: 12).familyName == "Onest")
    }

    @Test func monoIsFixedPitch() {
        let mono = BanditoFont.appKitMono(size: 12)
        #expect(mono.isFixedPitch)
    }

    @Test func terminalFontCanBeMadeBold() {
        // SwiftTerm builds its bold face with NSFontManager from the font it is given.
        let regular = BanditoFont.appKitTerminalMono(size: 13)
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        #expect(regular.isFixedPitch)
        #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        #expect(bold.fontName != regular.fontName)
    }

    @Test func weightSetsTheVariableAxis() {
        for family in [BanditoFont.displayFamily, BanditoFont.textFamily, BanditoFont.monoFamily] {
            let light = BanditoFont.ctFont(family: family, size: 14, weight: 400)
            let bold = BanditoFont.ctFont(family: family, size: 14, weight: 700)
            let lightWeight = axisValue(light)
            let boldWeight = axisValue(bold)
            #expect(lightWeight == 400, "\(family) regular is \(String(describing: lightWeight))")
            #expect(boldWeight == 700, "\(family) bold is \(String(describing: boldWeight))")
        }
    }

    @Test func weightIsClampedToTheAxis() {
        // Unbounded starts at 200, JetBrains Mono ends at 800.
        #expect(axisValue(BanditoFont.ctFont(family: BanditoFont.displayFamily, size: 14, weight: 50)) == 200)
        #expect(axisValue(BanditoFont.ctFont(family: BanditoFont.monoFamily, size: 14, weight: 900)) == 800)
    }

    @Test func eastAsianTextFallsBackToASystemFont() {
        let sample = "设置 設定 설정" as CFString
        for family in [BanditoFont.textFamily, BanditoFont.displayFamily] {
            let base = BanditoFont.ctFont(family: family, size: 14, weight: 400)
            #expect(CTFontCopyDefaultCascadeListForLanguages(base, nil) as? [Any] != nil)
            let cascade = CTFontCopyDefaultCascadeListForLanguages(base, nil) as? [CTFontDescriptor] ?? []
            #expect(!cascade.isEmpty, "\(family) has no fallback fonts")
            let used = CTFontCreateForString(base, sample, CFRange(location: 0, length: CFStringGetLength(sample)))
            #expect(CTFontCopyFamilyName(used) as String != family, "\(family) drew CJK itself")
        }
    }

    private func axisValue(_ font: CTFont) -> Double? {
        // CoreText leaves the axis out when it sits at the font's default (400).
        guard let variation = CTFontCopyVariation(font) as? [Int: Double] else { return nil }
        return variation[BanditoFont.weightAxis] ?? 400
    }
}
