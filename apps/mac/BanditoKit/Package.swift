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
    targets: [
        .target(name: "BanditoKit"),
        .target(name: "BanditoDesign", resources: [.process("Colors.xcassets")]),
        .target(name: "BanditoL10n", resources: [.process("Resources")]),
        .target(name: "BanditoUI", dependencies: ["BanditoKit", "BanditoDesign", "BanditoL10n"]),
        .testTarget(name: "BanditoKitTests", dependencies: ["BanditoKit", "BanditoL10n"]),
        .testTarget(name: "BanditoUITests", dependencies: ["BanditoUI", "BanditoKit", "BanditoL10n"]),
    ]
)
