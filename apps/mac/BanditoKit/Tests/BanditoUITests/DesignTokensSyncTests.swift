import Foundation
import Testing

/// The app's design tokens (`BanditoDesign`) are the ones `brand/tokens/build.py` generates from `tokens.json`: a token
/// changed in one place and not the other (the panels' spring, a colour) fails here.
@Suite struct DesignTokensSyncTests {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theAppsTokensAreTheGeneratedOnes() throws {
        let generated = Self.repo.appending(path: "brand/tokens/dist/BanditoTokens.swift")
        let app = Self.repo.appending(path: "apps/mac/BanditoKit/Sources/BanditoDesign/BanditoTokens.swift")
        guard FileManager.default.fileExists(atPath: generated.path) else { return }
        #expect(
            try String(contentsOf: generated, encoding: .utf8) == String(contentsOf: app, encoding: .utf8),
            "run python3 brand/tokens/build.py and copy dist/BanditoTokens.swift and Colors.xcassets to BanditoDesign")
    }

    @Test func theMotionTokensHoldTheDocumentedValues() throws {
        let json = Self.repo.appending(path: "brand/tokens/tokens.json")
        guard FileManager.default.fileExists(atPath: json.path) else { return }
        let tokens = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any]
        let motion = try #require(tokens?["motion"] as? [String: Any])
        #expect(motion["fast"] as? Int == 120 && motion["base"] as? Int == 200 && motion["slow"] as? Int == 320)
        #expect(motion["ease"] as? [Double] == [0.2, 0.8, 0.2, 1])
        #expect(motion["spring"] as? [Double] == [0.36, 0.9])
    }
}
