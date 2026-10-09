// swift-tools-version: 6.0
import PackageDescription

// Shared core of the Apple clients (Mac now, iPhone next):
// - BanditoKit: wire models, JSON-RPC client, transports, thread reducer, server model
// - BanditoDesign: brand tokens generated from brand/tokens
// - BanditoL10n: strings generated from i18n/*.json
// - BanditoUI: SwiftUI screens built on the three above
let package = Package(
    name: "BanditoKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BanditoKit", targets: ["BanditoKit"]),
        .library(name: "BanditoDesign", targets: ["BanditoDesign"]),
        .library(name: "BanditoL10n", targets: ["BanditoL10n"]),
        .library(name: "BanditoUI", targets: ["BanditoUI"]),
    ],
    dependencies: [
        // Terminal emulator for the Terminals mode. Pinned to the last stable minor: 1.99.0 and 1.20.0 are previews.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.19.0")),
        // VNC for the server screen (Screen mode). Pinned by revision (tag 1.1.0): RoyalVNCKit depends on a CryptoSwift branch, which SwiftPM refuses for tag requirements.
        .package(url: "https://github.com/royalapplications/royalvnc", revision: "92d4427c73817d8f849bb289ff190aa4b40c44ea"),
    ],
    targets: [
        .target(name: "BanditoKit", dependencies: ["BanditoL10n"]),
        .target(name: "BanditoDesign", resources: [.process("Colors.xcassets")]),
        .target(name: "BanditoL10n", resources: [.process("Resources")]),
        .target(
            name: "BanditoUI",
            dependencies: [
                "BanditoKit", "BanditoDesign", "BanditoL10n",
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "RoyalVNCKit", package: "royalvnc", condition: .when(platforms: [.macOS])),
            ]),
        .testTarget(name: "BanditoKitTests", dependencies: ["BanditoKit", "BanditoL10n"]),
        .testTarget(name: "BanditoUITests", dependencies: ["BanditoUI", "BanditoKit", "BanditoL10n"]),
    ]
)
